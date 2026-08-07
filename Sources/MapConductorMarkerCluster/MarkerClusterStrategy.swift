import Combine
import Foundation
import MapConductorCore
import UIKit

/// 近くのマーカーを 1 つにまとめて描くマーカーレンダリングストラテジ。
///
/// このファイルが持つのは**元データの保持と生成・破棄**だけで、実際の仕事は
/// 責務ごとに分けたファイルにある:
///
/// | ファイル                              | 担当                                       |
/// |---------------------------------------|--------------------------------------------|
/// | `MarkerClusterStrategy+Scheduling`    | いつ再クラスタするか（デバウンス・キュー） |
/// | `MarkerClusterStrategy+Clustering`    | 何をどこにまとめるか（前回結果の再利用）   |
/// | `MarkerClusterStrategy+Rendering`     | 計画と現状の差を描画へ反映                 |
/// | `MarkerClusterStrategy+Animation`     | クラスタとメンバーの間の移動アニメーション |
/// | `MarkerClusterStrategy+Spiderfy`      | クリックでメンバーを扇状に開く             |
/// | ``ClusterBuilder``                    | 近い候補の併合と中心の選び方               |
/// | ``ClusterGeometry``                   | 投影・境界・平均・凸包                     |
/// | ``SpiderfyLayout``                    | 扇の画面上の配置計算                       |
///
/// **計算だけの部分は型として切り出し、状態に触る部分は extension にしてある。**
/// Swift の Dictionary は値型なので、`renderedMarkerEntities` のような共有可変状態を
/// 別の型へ渡すと写しになってしまう。参照型の入れ物を挟めば型に分けられるが、
/// ロックと MainActor の絡む場所を作り替えることになるため、ここでは
/// 同じインスタンスの extension に留めている
/// （android-sdk はこの制約が無いので `ClusterMarkerRenderer` などの型に分けてある）。
///
/// extension から触るため、状態のプロパティはモジュール内公開になっている。
/// このモジュールにはクラスタリング関連しか入っていないので、実質はこのファイル群専用。
public final class MarkerClusterStrategy<ActualMarker>: AbstractMarkerRenderingStrategy<ActualMarker> {
    public static var DEFAULT_CLUSTER_RADIUS_PX: Double { markerClusterDefaultClusterRadiusPx }
    public static var DEFAULT_MIN_CLUSTER_SIZE: Int { markerClusterDefaultMinClusterSize }
    public static var DEFAULT_EXPAND_MARGIN: Double { markerClusterDefaultExpandMargin }
    public static var DEFAULT_TILE_SIZE: Double { markerClusterDefaultTileSize }
    public static var DEFAULT_ZOOM_ANIMATION_DURATION_MILLIS: Int { markerClusterDefaultZoomAnimationDurationMillis }
    public static var DEFAULT_CAMERA_DEBOUNCE_MILLIS: Int { markerClusterCameraDebounceMillis }
    public static var DEFAULT_SPIDERFY_MARKER_SIZE_PX: Double { markerClusterDefaultSpiderfyMarkerSizePx }
    public static var DEFAULT_SPIDERFY_MARKER_MARGIN_PX: Double { markerClusterDefaultSpiderfyMarkerMarginPx }
    public static var DEFAULT_SPIDERFY_LEG_COLOR: UIColor { markerClusterDefaultSpiderfyLegColor }
    public static var DEFAULT_SPIDERFY_LEG_WIDTH: Double { markerClusterDefaultSpiderfyLegWidth }

    static var minZoomDeltaForRender: Double { markerClusterMinZoomDeltaForRender }

    public typealias ClusterIconProvider = (Int) -> MarkerIconProtocol
    public typealias ClusterIconProviderWithTurn = (Int, Int) -> MarkerIconProtocol

    let instanceId: Int = MarkerClusterStrategyInstanceId.allocate()

    public let clusterRadiusPx: Double
    public let minClusterSize: Int
    public let expandMargin: Double
    public let clusterIconProvider: ClusterIconProvider
    public let clusterIconProviderWithTurn: ClusterIconProviderWithTurn?
    public let tileSize: Double
    public let onClusterClick: ((MarkerCluster) -> Void)?
    public let enableZoomAnimation: Bool
    public let enablePanAnimation: Bool
    public let zoomAnimationDurationMillis: Int
    public let cameraIdleDebounceMillis: Int
    public let debugHullPolygons: Bool
    /// At or above this zoom, clicking a cluster fans its members out around
    /// the (kept) cluster marker, connected by leg polylines — useful when
    /// multiple markers share the same location and can never be separated by
    /// zooming. Clicking the same cluster again, or any recluster (camera
    /// move / data change), collapses the fan. Below this zoom the click
    /// falls through to `onClusterClick`. `nil` disables the feature.
    public let spiderfyMinZoom: Double?
    /// Marker diameter in px used by the overlap-avoiding layout (default 52).
    public let spiderfyMarkerSizePx: Double
    /// Extra gap between fanned-out markers in px (default 8).
    public let spiderfyMarkerMarginPx: Double
    /// Leg polyline color (default #666666).
    public let spiderfyLegColor: UIColor
    /// Leg polyline width (default 1.5).
    public let spiderfyLegWidth: Double
    /// Called when a spiderfy fan opens (true) or collapses (false) — e.g. to
    /// close an info bubble when the user clicks another cluster or the fan
    /// is dismissed by a camera move.
    public let onSpiderfyChange: ((Bool) -> Void)?
    /// Called before newly appearing individual (non-cluster) markers are
    /// rendered — e.g. when a cluster expands after a zoom. Rendering of the
    /// new cluster state is deferred until the callback returns, so the app
    /// can preload marker icon images (and show a loading indicator) before
    /// the markers pop in. A newer recluster supersedes any pending deferred
    /// apply.
    public let prepareExpand: (([MarkerState]) async -> Void)?

    /// Called synchronously before marker animations start, after cluster computation.
    /// Set via ``MarkerClusterGroupState/bindPolygonSync(_:)`` to commit hull polygon
    /// updates before animations begin, so polygon rendering and marker animation cannot race.
    public var onBeforeAnimation: (([MarkerClusterDebugInfo]) async -> Void)?

    // ── 計算だけを持つ部品（差し替え可能な唯一の継ぎ目） ────────────────────
    let geometry: ClusterGeometry
    let builder: ClusterBuilder

    // ── 元データ ────────────────────────────────────────────────────────────
    var sourceStates: [String: MarkerState] = [:]
    var sourceFingerprints: [String: MarkerFingerPrint] = [:]
    let sourceStatesLock = NSLock()
    var sourceStateVersion: Int64 = 0

    // ── カメラと再クラスタの段取り ──────────────────────────────────────────
    var lastCameraPosition: MapCameraPosition?
    var debounceTask: Task<Void, Never>?
    var cameraUpdateToken: Int64 = 0
    let tokenLock = NSLock()
    let renderQueueState = RenderQueueState()
    var renderTask: Task<Void, Never>?
    var lastViewport: GeoRectBounds?
    var lastKnownViewportZoom: Double?
    let rendererBox = MainQueueReleaseBox<AnyMarkerOverlayRenderer<ActualMarker>>()

    // ── 前回の描画結果（次回の再利用のためだけに持つ） ──────────────────────
    let renderStateLock = NSLock()
    var clusteringTurn: Int = 0
    var lastZoomKey: Int?
    var lastClusterMemberCenters: [String: GeoPoint] = [:]
    var lastClusterPositions: [String: GeoPoint] = [:]
    var lastRenderCameraPosition: MapCameraPosition?
    var renderedMarkerEntities: [String: MarkerEntity<ActualMarker>] = [:]
    var lastExpandedBounds: GeoRectBounds?
    var lastClusterCoverageBounds: GeoRectBounds?
    var lastClusterAssignments: [String: String] = [:]  // markerID -> clusterID
    var lastSourceStateVersion: Int64 = 0
    var lastSourceFingerprints: [String: MarkerFingerPrint] = [:]
    var forceNextRender: Bool = false

    let debugInfoSubject = CurrentValueSubject<[MarkerClusterDebugInfo], Never>([])
    public var debugInfoFlow: CurrentValueSubject<[MarkerClusterDebugInfo], Never> { debugInfoSubject }
    /// Leg polylines of the currently open spiderfy fan (empty when collapsed).
    /// ``MarkerClusterGroupState`` republishes this so `MarkerClusterGroup` can
    /// render the legs declaratively, the same way debug circles are rendered.
    let spiderfyLegsSubject = CurrentValueSubject<[PolylineState], Never>([])
    public var spiderfyLegsFlow: CurrentValueSubject<[PolylineState], Never> { spiderfyLegsSubject }

    // Spiderfy runtime state. Only touched from @MainActor methods
    // (trySpiderfy / applySpiderfy / collapseSpiderfy) and clear()'s MainActor task.
    var spiderfyClusterKey: String?
    var spiderfyEntities: [MarkerEntity<ActualMarker>] = []
    // Monotonic token: collapsing (or a newer open) invalidates an apply that is
    // still waiting on prepareExpand, so a stale fan is never rendered.
    var spiderfyToken: Int = 0

    public init(
        clusterRadiusPx: Double = DEFAULT_CLUSTER_RADIUS_PX,
        minClusterSize: Int = DEFAULT_MIN_CLUSTER_SIZE,
        expandMargin: Double = DEFAULT_EXPAND_MARGIN,
        clusterIconProvider: @escaping ClusterIconProvider = MarkerClusterStrategy.defaultIconProvider,
        clusterIconProviderWithTurn: ClusterIconProviderWithTurn? = nil,
        onClusterClick: ((MarkerCluster) -> Void)? = nil,
        enableZoomAnimation: Bool = false,
        enablePanAnimation: Bool = false,
        zoomAnimationDurationMillis: Int = DEFAULT_ZOOM_ANIMATION_DURATION_MILLIS,
        cameraIdleDebounceMillis: Int = DEFAULT_CAMERA_DEBOUNCE_MILLIS,
        tileSize: Double = DEFAULT_TILE_SIZE,
        debugHullPolygons: Bool = false,
        spiderfyMinZoom: Double? = nil,
        spiderfyMarkerSizePx: Double = DEFAULT_SPIDERFY_MARKER_SIZE_PX,
        spiderfyMarkerMarginPx: Double = DEFAULT_SPIDERFY_MARKER_MARGIN_PX,
        spiderfyLegColor: UIColor = DEFAULT_SPIDERFY_LEG_COLOR,
        spiderfyLegWidth: Double = DEFAULT_SPIDERFY_LEG_WIDTH,
        onSpiderfyChange: ((Bool) -> Void)? = nil,
        prepareExpand: (([MarkerState]) async -> Void)? = nil,
        semaphore: AsyncSemaphore = AsyncSemaphore(1),
        geocell: HexGeocellProtocol = HexGeocell.defaultGeocell()
    ) {
        self.clusterRadiusPx = clusterRadiusPx
        self.minClusterSize = minClusterSize
        self.expandMargin = expandMargin
        self.clusterIconProvider = clusterIconProvider
        self.clusterIconProviderWithTurn = clusterIconProviderWithTurn
        self.onClusterClick = onClusterClick
        self.enableZoomAnimation = enableZoomAnimation
        self.enablePanAnimation = enablePanAnimation
        self.zoomAnimationDurationMillis = zoomAnimationDurationMillis
        self.cameraIdleDebounceMillis = cameraIdleDebounceMillis
        self.tileSize = tileSize
        self.debugHullPolygons = debugHullPolygons
        self.spiderfyMinZoom = spiderfyMinZoom
        self.spiderfyMarkerSizePx = spiderfyMarkerSizePx
        self.spiderfyMarkerMarginPx = spiderfyMarkerMarginPx
        self.spiderfyLegColor = spiderfyLegColor
        self.spiderfyLegWidth = spiderfyLegWidth
        self.onSpiderfyChange = onSpiderfyChange
        self.prepareExpand = prepareExpand
        let geometry = ClusterGeometry(tileSize: tileSize)
        self.geometry = geometry
        self.builder = ClusterBuilder(geometry: geometry, clusterRadiusPx: clusterRadiusPx)
        // Android: `MarkerManager(geocell, 0)` — minMarkerCount 0 keeps the hex spatial
        // index enabled from the first marker rather than only above MarkerManager's
        // 2000 default, so cluster hit-testing behaves the same on both platforms.
        super.init(
            markerManager: MarkerManager(geocell: geocell, minMarkerCount: 0),
            semaphore: semaphore
        )
    }

    deinit {
        MCLog.marker("MarkerClusterStrategy[\(instanceId)].deinit")
        // Increment token first to stop any ongoing operations
        _ = incrementToken()

        // Cancel debounce task
        debounceTask?.cancel()
        debounceTask = nil

        // Clear queue and cancel render task
        // Note: We can't await in deinit, but clearing the queue will cause
        // processRenderQueue to exit naturally on its next iteration
        let queueState = renderQueueState
        Task {
            await queueState.clear()
        }

        // Cancel render task - it should exit due to token check
        renderTask?.cancel()
        renderTask = nil
    }

    public override func clear() {
        MCLog.marker("MarkerClusterStrategy[\(instanceId)].clear")
        // Increment token first to stop any ongoing operations
        _ = incrementToken()

        // Cancel debounce task
        debounceTask?.cancel()
        debounceTask = nil

        // Clear queue and cancel render task
        let queueState = renderQueueState
        Task {
            await queueState.clear()
        }
        renderTask?.cancel()
        renderTask = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rendererBox.set(nil)
            // Reset spiderfy bookkeeping; a pending prepareExpand-deferred apply
            // is invalidated by the token bump.
            self.spiderfyToken += 1
            self.spiderfyClusterKey = nil
            self.spiderfyEntities = []
            self.spiderfyLegsSubject.value = []
        }

        // Clear state
        sourceStates.removeAll()
        sourceFingerprints.removeAll()
        markerManager.clear()
        debugInfoSubject.value = []

        renderStateLock.lock()
        lastClusterMemberCenters = [:]
        lastClusterPositions = [:]
        lastRenderCameraPosition = nil
        renderedMarkerEntities.removeAll()
        lastZoomKey = nil
        clusteringTurn = 0
        lastExpandedBounds = nil
        lastClusterCoverageBounds = nil
        lastClusterAssignments = [:]
        lastSourceStateVersion = 0
        lastSourceFingerprints = [:]
        forceNextRender = false
        renderStateLock.unlock()
        lastKnownViewportZoom = nil

        sourceStatesLock.lock()
        sourceStateVersion = 0
        sourceStatesLock.unlock()
    }

    // ── 基底クラスの入口 ────────────────────────────────────────────────────
    // Swift は extension で override できないため、宣言だけここに置き、中身は
    // `MarkerClusterStrategy+Scheduling` に委譲している。

    public override func onAdd<Renderer: MarkerOverlayRendererProtocol>(
        data: [MarkerState],
        viewport: GeoRectBounds,
        renderer: Renderer
    ) async -> Bool where Renderer.ActualMarker == ActualMarker {
        await handleAdd(data: data, viewport: viewport, renderer: renderer)
    }

    public override func onUpdate<Renderer: MarkerOverlayRendererProtocol>(
        state: MarkerState,
        viewport: GeoRectBounds,
        renderer: Renderer
    ) async -> Bool where Renderer.ActualMarker == ActualMarker {
        await handleUpdate(state: state, viewport: viewport, renderer: renderer)
    }

    public override func onCameraChanged<Renderer: MarkerOverlayRendererProtocol>(
        mapCameraPosition: MapCameraPosition,
        renderer: Renderer
    ) async where Renderer.ActualMarker == ActualMarker {
        await handleCameraChanged(mapCameraPosition: mapCameraPosition, renderer: renderer)
    }

    /// ズームが変わったかを見て、変わっていれば周回数を進める。
    ///
    /// 周回数はアイコン提供側（`clusterIconProviderWithTurn`）へ渡り、
    /// 「ズームするたびに色を変える」といった表現に使われる。
    /// 小数第 2 位まででズームを丸めるので、わずかな揺れでは進まない。
    func updateClusteringTurn(zoom: Double) -> ZoomChange {
        let zoomKey = Int((zoom * 100.0).rounded())
        if lastZoomKey == nil {
            clusteringTurn = 1
            lastZoomKey = zoomKey
            return ZoomChange(turn: clusteringTurn, zoomChanged: false)
        }
        let zoomChanged = lastZoomKey != zoomKey
        if zoomChanged {
            clusteringTurn += 1
            lastZoomKey = zoomKey
        }
        return ZoomChange(turn: clusteringTurn, zoomChanged: zoomChanged)
    }

    func incrementToken() -> Int64 {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        cameraUpdateToken += 1
        return cameraUpdateToken
    }

    func currentToken() -> Int64 {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return cameraUpdateToken
    }

    /// Forces a full cluster recompute on the next render, bypassing the coverage-bounds
    /// early-return. Called by ``MarkerClusterGroupState`` to ensure hull polygons reflect
    /// the current camera position immediately when ``debugHullPolygons`` is enabled.
    @MainActor
    public func forceRender() {
        guard let cameraPosition = lastCameraPosition,
              let viewport = lastViewport else { return }
        renderStateLock.lock()
        forceNextRender = true
        renderStateLock.unlock()
        let token = incrementToken()
        enqueueRender(cameraPosition: cameraPosition, viewport: viewport, token: token)
    }

    public static var defaultIconProvider: ClusterIconProvider {
        { count in DefaultMarkerIcon(label: String(count)) }
    }

    struct ZoomChange {
        let turn: Int
        let zoomChanged: Bool
    }

    /// 出てくるマーカー 1 件と、その出発点。
    struct AnimatedAdd {
        let state: MarkerState
        let start: GeoPoint
    }

    /// 消えるマーカー 1 件と、その行き先。
    struct AnimatedRemove {
        let entity: MarkerEntity<ActualMarker>
        let target: GeoPoint
    }

    /// アニメーションで動かす 1 件。`entity` は 1 フレームごとに差し替わる。
    struct AnimatedMove {
        let id: String
        let start: GeoPointProtocol
        let end: GeoPointProtocol
        let baseState: MarkerState
        var entity: MarkerEntity<ActualMarker>
    }
}

extension MarkerClusterStrategy: PolygonSyncHandler {
    /// Wires up the strategy's ``onBeforeAnimation`` so hull polygons are committed
    /// synchronously before marker animations start.
    /// Called by the map view coordinator on every `updateContent` pass.
    public func bindPolygonSync(_ polygonSync: @escaping @MainActor ([PolygonState]) async -> Void) {
        guard debugHullPolygons else {
            onBeforeAnimation = nil
            return
        }
        onBeforeAnimation = { debugInfos in
            let states = makeHullPolygonStates(
                from: debugInfos,
                strokeAlpha: 0.8,
                fillAlpha: 0.18,
                strokeWidth: 2.0
            )
            await polygonSync(states)
        }
    }
}
