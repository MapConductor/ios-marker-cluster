import Combine
import MapConductorCore
import UIKit

// Debug hull polygon styling. Fixed rather than configurable: `debugHullPolygons`
// is the only debug knob the public API exposes on all three platforms.
private let markerClusterDebugHullStrokeWidth: Double = 2.0
private let markerClusterDebugHullStrokeAlpha: CGFloat = 0.8
private let markerClusterDebugHullFillAlpha: CGFloat = 0.18

/// Android SDK の `MarkerClusterGroupState` に対応する iOS 側の State コンテナです。
/// Android と同様にジェネリクスを持たない設定ホルダーで、プロバイダごとの
/// `MarkerClusterStrategy<ActualMarker>` は ``strategy(for:)`` で遅延生成・キャッシュします。
/// クラスタリング設定の変更時は戦略を再生成しますが、`debugHullPolygons` の変更は
/// 戦略インスタンスを使い回したまま `forceRender()` で即時反映します（Android と同方式）。
public final class MarkerClusterGroupState: ObservableObject {
    public typealias ClusterIconProvider = (Int) -> MarkerIconProtocol
    public typealias ClusterIconProviderWithTurn = (Int, Int) -> MarkerIconProtocol
    public typealias PrepareExpand = ([MarkerState]) async -> Void

    @Published public var clusterRadiusPx: Double { didSet { rebuildStrategies() } }
    @Published public var minClusterSize: Int { didSet { rebuildStrategies() } }
    @Published public var expandMargin: Double { didSet { rebuildStrategies() } }
    @Published public var clusterIconProvider: ClusterIconProvider { didSet { rebuildStrategies() } }
    @Published public var clusterIconProviderWithTurn: ClusterIconProviderWithTurn? { didSet { rebuildStrategies() } }
    @Published public var onClusterClick: ((MarkerCluster) -> Void)? { didSet { rebuildStrategies() } }
    @Published public var enableZoomAnimation: Bool { didSet { rebuildStrategies() } }
    @Published public var enablePanAnimation: Bool { didSet { rebuildStrategies() } }
    @Published public var zoomAnimationDurationMillis: Int { didSet { rebuildStrategies() } }
    @Published public var cameraIdleDebounceMillis: Int { didSet { rebuildStrategies() } }
    @Published public var tileSize: Double { didSet { rebuildStrategies() } }
    /// 展開直前に新しく出現する個別マーカーを引数に呼ばれる非同期コールバック。
    /// 戻るまで新しいクラスタ状態の描画を遅延するので、アイコンの事前読み込み等に使えます。
    @Published public var prepareExpand: PrepareExpand? { didSet { rebuildStrategies() } }
    /// このズーム以上でクラスタをクリックすると、メンバーをクラスタマーカーの周囲に
    /// 扇状展開(spiderfy)します。`nil` で無効。
    @Published public var spiderfyMinZoom: Double? { didSet { rebuildStrategies() } }
    @Published public var spiderfyMarkerSizePx: Double { didSet { rebuildStrategies() } }
    @Published public var spiderfyMarkerMarginPx: Double { didSet { rebuildStrategies() } }
    @Published public var spiderfyLegColor: UIColor { didSet { rebuildStrategies() } }
    @Published public var spiderfyLegWidth: Double { didSet { rebuildStrategies() } }
    /// spiderfy の展開(true)/収納(false)時に呼ばれます。
    @Published public var onSpiderfyChange: ((Bool) -> Void)? { didSet { rebuildStrategies() } }
    /// 現在開いている spiderfy の脚線。`MarkerClusterGroup` が宣言的に描画します。
    @Published public private(set) var spiderfyLegs: [PolylineState] = []

    @Published public var debugHullPolygons: Bool = false {
        didSet {
            guard debugHullPolygons != oldValue else { return }
            guard let fn = polygonSyncFn else {
                // The map hasn't wired up yet; forceRender() will be called from
                // bindPolygonSync() once the coordinator attaches the sync callback.
                return
            }
            // polygon sync already wired up — update onBeforeAnimation in-place and
            // force an immediate re-cluster so polygons reflect the current viewport.
            strategies.values.forEach { applyPolygonSync(to: $0) }
            if debugHullPolygons {
                forceRenderAll()
            } else {
                // Clear existing hull polygons immediately.
                Task { @MainActor in await fn([]) }
            }
        }
    }
    @Published public private(set) var debugInfos: [MarkerClusterDebugInfo] = []

    private var strategies: [ObjectIdentifier: any MarkerClusterStrategyBase] = [:]
    // Recreates each cached strategy with its original ActualMarker type after a config change.
    private var strategyRebuilders: [ObjectIdentifier: () -> Void] = [:]
    private var debugInfoCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var spiderfyLegCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    // Stored so config changes and rebinds can re-apply it to every strategy instance.
    private var polygonSyncFn: (@MainActor ([PolygonState]) async -> Void)?

    public init(
        clusterRadiusPx: Double = MarkerClusterDefaults.clusterRadiusPx,
        minClusterSize: Int = MarkerClusterDefaults.minClusterSize,
        expandMargin: Double = MarkerClusterDefaults.expandMargin,
        clusterIconProvider: @escaping ClusterIconProvider = MarkerClusterDefaults.iconProvider,
        clusterIconProviderWithTurn: ClusterIconProviderWithTurn? = nil,
        onClusterClick: ((MarkerCluster) -> Void)? = nil,
        enableZoomAnimation: Bool = false,
        enablePanAnimation: Bool = false,
        zoomAnimationDurationMillis: Int = MarkerClusterDefaults.zoomAnimationDurationMillis,
        cameraIdleDebounceMillis: Int = MarkerClusterDefaults.cameraIdleDebounceMillis,
        tileSize: Double = MarkerClusterDefaults.tileSize,
        debugHullPolygons: Bool = false,
        prepareExpand: PrepareExpand? = nil,
        spiderfyMinZoom: Double? = nil,
        spiderfyMarkerSizePx: Double = MarkerClusterDefaults.spiderfyMarkerSizePx,
        spiderfyMarkerMarginPx: Double = MarkerClusterDefaults.spiderfyMarkerMarginPx,
        spiderfyLegColor: UIColor = MarkerClusterDefaults.spiderfyLegColor,
        spiderfyLegWidth: Double = MarkerClusterDefaults.spiderfyLegWidth,
        onSpiderfyChange: ((Bool) -> Void)? = nil
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
        self.prepareExpand = prepareExpand
        self.spiderfyMinZoom = spiderfyMinZoom
        self.spiderfyMarkerSizePx = spiderfyMarkerSizePx
        self.spiderfyMarkerMarginPx = spiderfyMarkerMarginPx
        self.spiderfyLegColor = spiderfyLegColor
        self.spiderfyLegWidth = spiderfyLegWidth
        self.onSpiderfyChange = onSpiderfyChange
        self.debugHullPolygons = debugHullPolygons
    }

    /// 指定した ActualMarker 型向けの戦略を返します。初回アクセス時に現在の設定で生成し、
    /// 以降は同じインスタンスを返します。`MarkerClusterGroup` が内部で使用します。
    public func strategy<ActualMarker>(
        for markerType: ActualMarker.Type = ActualMarker.self
    ) -> MarkerClusterStrategy<ActualMarker> {
        let key = ObjectIdentifier(markerType)
        if let existing = strategies[key] as? MarkerClusterStrategy<ActualMarker> {
            return existing
        }
        return registerStrategy(for: markerType)
    }

    @discardableResult
    private func registerStrategy<ActualMarker>(
        for markerType: ActualMarker.Type
    ) -> MarkerClusterStrategy<ActualMarker> {
        let key = ObjectIdentifier(markerType)
        let strategy = MarkerClusterStrategy<ActualMarker>(
            clusterRadiusPx: clusterRadiusPx,
            minClusterSize: minClusterSize,
            expandMargin: expandMargin,
            clusterIconProvider: clusterIconProvider,
            clusterIconProviderWithTurn: clusterIconProviderWithTurn,
            onClusterClick: onClusterClick,
            enableZoomAnimation: enableZoomAnimation,
            enablePanAnimation: enablePanAnimation,
            zoomAnimationDurationMillis: zoomAnimationDurationMillis,
            cameraIdleDebounceMillis: cameraIdleDebounceMillis,
            tileSize: tileSize,
            debugHullPolygons: debugHullPolygons,
            spiderfyMinZoom: spiderfyMinZoom,
            spiderfyMarkerSizePx: spiderfyMarkerSizePx,
            spiderfyMarkerMarginPx: spiderfyMarkerMarginPx,
            spiderfyLegColor: spiderfyLegColor,
            spiderfyLegWidth: spiderfyLegWidth,
            onSpiderfyChange: onSpiderfyChange,
            prepareExpand: prepareExpand
        )
        strategies[key] = strategy
        strategyRebuilders[key] = { [weak self] in
            self?.registerStrategy(for: markerType)
        }
        applyPolygonSync(to: strategy)
        bindDebugInfo(strategy, key: key)
        bindSpiderfyLegs(strategy, key: key)
        return strategy
    }

    private func rebuildStrategies() {
        strategies.values.forEach { $0.clear() }
        strategies.removeAll()
        debugInfoCancellables.removeAll()
        spiderfyLegCancellables.removeAll()
        spiderfyLegs = []
        // Recreate eagerly so MarkerClusterGroup picks up the new instances on the next build.
        strategyRebuilders.values.forEach { $0() }
    }

    private func bindDebugInfo(_ strategy: any MarkerClusterStrategyBase, key: ObjectIdentifier) {
        debugInfoCancellables[key] = strategy.debugInfoFlow
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.debugInfos = $0
            }
    }

    private func bindSpiderfyLegs(_ strategy: any MarkerClusterStrategyBase, key: ObjectIdentifier) {
        spiderfyLegCancellables[key] = strategy.spiderfyLegsFlow
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.spiderfyLegs = $0
            }
    }

    private func applyPolygonSync(to strategy: any MarkerClusterStrategyBase) {
        guard let sync = polygonSyncFn, debugHullPolygons else {
            strategy.onBeforeAnimation = nil
            return
        }
        let strokeAlpha = markerClusterDebugHullStrokeAlpha
        let fillAlpha = markerClusterDebugHullFillAlpha
        let strokeWidth = markerClusterDebugHullStrokeWidth
        strategy.onBeforeAnimation = { debugInfos in
            let states = makeHullPolygonStates(
                from: debugInfos,
                strokeAlpha: strokeAlpha,
                fillAlpha: fillAlpha,
                strokeWidth: strokeWidth
            )
            await sync(states)
        }
    }

    private func forceRenderAll() {
        let targets = Array(strategies.values)
        Task { @MainActor in
            targets.forEach { $0.forceRender() }
        }
    }
}

extension MarkerClusterGroupState: PolygonSyncHandler {
    public func bindPolygonSync(_ polygonSync: @escaping @MainActor ([PolygonState]) async -> Void) {
        let isFirstBind = polygonSyncFn == nil
        polygonSyncFn = polygonSync
        strategies.values.forEach { applyPolygonSync(to: $0) }
        // First time the coordinator wires up polygon sync while debug is already ON:
        // force an immediate render so polygons appear without needing a camera nudge.
        if isFirstBind && debugHullPolygons {
            forceRenderAll()
        }
    }
}
