import MapConductorCore
import UIKit

private let markerClusterGroupClusterCircleIdPrefix = "cluster-circle-"
let markerClusterGroupHullPolygonIdPrefix = "cluster-hull-"
let debugHullPalette: [UIColor] = [
    .systemBlue, .systemGreen, .systemRed, .systemOrange,
    .systemPurple, .systemCyan, .systemYellow, .systemPink,
]

/// Builds `PolygonState` objects for cluster hull polygons from debug infos.
/// Used by ``MarkerClusterGroupState`` via `onBeforeAnimation` for imperative polygon management.
func makeHullPolygonStates(
    from debugInfos: [MarkerClusterDebugInfo],
    strokeAlpha: CGFloat,
    fillAlpha: CGFloat,
    strokeWidth: Double
) -> [PolygonState] {
    debugInfos
        .filter { $0.hullPoints.count >= 3 }
        .enumerated()
        .map { index, info in
            let base = debugHullPalette[index % debugHullPalette.count]
            return PolygonState(
                points: info.hullPoints,
                id: "\(markerClusterGroupHullPolygonIdPrefix)\(info.id)",
                strokeColor: base.withAlphaComponent(strokeAlpha),
                strokeWidth: strokeWidth,
                fillColor: base.withAlphaComponent(fillAlpha),
                geodesic: false,
                zIndex: 9,
                extra: info,
                onClick: nil
            )
        }
}

/// Android SDKの`MarkerClusterGroup`に合わせた、iOS側の薄いラッパーです。
public struct MarkerClusterGroup<ActualMarker>: MapOverlayItemProtocol {
    public let strategy: AnyMarkerRenderingStrategy<ActualMarker>
    public let markers: [MarkerState]
    private let overlayContent: MapViewContent
    // Passed to MapViewContent so the map view coordinator can wire up imperative
    // polygon sync via PolygonSyncHandler. State-backed groups keep this connected
    // so debug hull polygons can be cleared when the switch is turned off.
    private let polygonSyncHandler: (any PolygonSyncHandler)?

    public init(
        strategy: MarkerClusterStrategy<ActualMarker>,
        markers: [MarkerState]
    ) {
        self.strategy = AnyMarkerRenderingStrategy(strategy)
        self.markers = markers
        self.overlayContent = MapViewContent()
        self.polygonSyncHandler = nil
    }

    public init(
        state: MarkerClusterGroupState,
        markers: [MarkerState]
    ) {
        self.strategy = AnyMarkerRenderingStrategy(state.strategy(for: ActualMarker.self))
        self.markers = markers
        self.overlayContent = MapViewContent()
        self.polygonSyncHandler = state
    }

    public init(
        clusterRadiusPx: Double = MarkerClusterStrategy<ActualMarker>.DEFAULT_CLUSTER_RADIUS_PX,
        minClusterSize: Int = MarkerClusterStrategy<ActualMarker>.DEFAULT_MIN_CLUSTER_SIZE,
        expandMargin: Double = MarkerClusterStrategy<ActualMarker>.DEFAULT_EXPAND_MARGIN,
        clusterIconProvider: @escaping MarkerClusterStrategy<ActualMarker>.ClusterIconProvider = MarkerClusterStrategy<ActualMarker>.defaultIconProvider,
        clusterIconProviderWithTurn: MarkerClusterStrategy<ActualMarker>.ClusterIconProviderWithTurn? = nil,
        onClusterClick: ((MarkerCluster) -> Void)? = nil,
        enableZoomAnimation: Bool = false,
        enablePanAnimation: Bool = false,
        zoomAnimationDurationMillis: Int = MarkerClusterStrategy<ActualMarker>.DEFAULT_ZOOM_ANIMATION_DURATION_MILLIS,
        cameraIdleDebounceMillis: Int = MarkerClusterStrategy<ActualMarker>.DEFAULT_CAMERA_DEBOUNCE_MILLIS,
        tileSize: Double = MarkerClusterStrategy<ActualMarker>.DEFAULT_TILE_SIZE,
        @MapViewContentBuilder content: () -> MapViewContent
    ) {
        self.init(
            strategy: MarkerClusterStrategy(
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
                tileSize: tileSize
            ),
            content: content
        )
    }

    public init(
        strategy: MarkerClusterStrategy<ActualMarker>,
        @MapViewContentBuilder content: () -> MapViewContent
    ) {
        let inner = content()
        var seenIds = Set<String>()
        let markerStates =
            (inner.markerRenderingMarkers + inner.markers.map(\.state))
            .filter { seenIds.insert($0.id).inserted }

        self.strategy = AnyMarkerRenderingStrategy(strategy)
        self.markers = markerStates

        var passthrough = inner
        passthrough.markers = []
        passthrough.markerRenderingStrategy = nil
        passthrough.markerRenderingMarkers = []

        // Hull polygons are managed imperatively via onBeforeAnimation; skip declarative build.
        self.overlayContent = passthrough
        self.polygonSyncHandler = strategy.debugHullPolygons ? strategy : nil
    }

    public init(
        state: MarkerClusterGroupState,
        @MapViewContentBuilder content: () -> MapViewContent
    ) {
        let inner = content()
        var seenIds = Set<String>()
        let markerStates =
            (inner.markerRenderingMarkers + inner.markers.map(\.state))
            .filter { seenIds.insert($0.id).inserted }

        self.strategy = AnyMarkerRenderingStrategy(state.strategy(for: ActualMarker.self))
        self.markers = markerStates

        var passthrough = inner
        passthrough.markers = []
        passthrough.markerRenderingStrategy = nil
        passthrough.markerRenderingMarkers = []

        if state.showClusterRadiusCircle {
            let circles = state.debugInfos.map { info in
                Circle(
                    center: info.center,
                    radiusMeters: info.radiusMeters,
                    geodesic: true,
                    clickable: false,
                    strokeColor: state.clusterRadiusStrokeColor,
                    strokeWidth: state.clusterRadiusStrokeWidth,
                    fillColor: state.clusterRadiusFillColor,
                    id: "\(markerClusterGroupClusterCircleIdPrefix)\(info.id)",
                    zIndex: nil,
                    extra: info,
                    onClick: nil
                )
            }
            passthrough.circles.append(contentsOf: circles)
        }

        // Hull polygons are managed imperatively via the state so they can also be
        // cleared when debugHullPolygons is turned off.
        self.overlayContent = passthrough
        self.polygonSyncHandler = state
    }

    public func append(to content: inout MapViewContent) {
        content.infoBubbles.append(contentsOf: overlayContent.infoBubbles)
        content.polylines.append(contentsOf: overlayContent.polylines)
        content.polygons.append(contentsOf: overlayContent.polygons)
        content.circles.append(contentsOf: overlayContent.circles)
        content.rasterLayers.append(contentsOf: overlayContent.rasterLayers)
        content.views.append(contentsOf: overlayContent.views)
        content.markerRenderingStrategy = strategy
        content.markerRenderingMarkers = markers
        if let handler = polygonSyncHandler {
            content.polygonSyncHandlers.append(handler)
        }
    }
}
