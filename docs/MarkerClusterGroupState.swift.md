# MarkerClusterGroupState

An `ObservableObject` that holds the configuration for a `MarkerClusterGroup`. When any
`@Published` property changes the clustering strategy is automatically rebuilt via `rebuildStrategy()`.

## Signature

```swift
public final class MarkerClusterGroupState<ActualMarker>: ObservableObject {
    public typealias ClusterIconProvider = MarkerClusterStrategy<ActualMarker>.ClusterIconProvider
    public typealias ClusterIconProviderWithTurn = MarkerClusterStrategy<ActualMarker>.ClusterIconProviderWithTurn

    @Published public var clusterRadiusPx: Double
    @Published public var minClusterSize: Int
    @Published public var expandMargin: Double
    @Published public var clusterIconProvider: ClusterIconProvider
    @Published public var clusterIconProviderWithTurn: ClusterIconProviderWithTurn?
    @Published public var onClusterClick: ((MarkerCluster) -> Void)?
    @Published public var enableZoomAnimation: Bool
    @Published public var enablePanAnimation: Bool
    @Published public var zoomAnimationDurationMillis: Int
    @Published public var cameraIdleDebounceMillis: Int
    @Published public var tileSize: Double
    @Published public var showClusterRadiusCircle: Bool
    @Published public var clusterRadiusStrokeColor: UIColor
    @Published public var clusterRadiusStrokeWidth: Double
    @Published public var clusterRadiusFillColor: UIColor
    @Published public private(set) var debugInfos: [MarkerClusterDebugInfo]

    public private(set) var strategy: MarkerClusterStrategy<ActualMarker>

    public init(
        clusterRadiusPx: Double = MarkerClusterStrategy<ActualMarker>.DEFAULT_CLUSTER_RADIUS_PX,
        minClusterSize: Int = MarkerClusterStrategy<ActualMarker>.DEFAULT_MIN_CLUSTER_SIZE,
        expandMargin: Double = MarkerClusterStrategy<ActualMarker>.DEFAULT_EXPAND_MARGIN,
        clusterIconProvider: @escaping ClusterIconProvider
            = MarkerClusterStrategy<ActualMarker>.defaultIconProvider,
        clusterIconProviderWithTurn: ClusterIconProviderWithTurn? = nil,
        onClusterClick: ((MarkerCluster) -> Void)? = nil,
        enableZoomAnimation: Bool = false,
        enablePanAnimation: Bool = false,
        zoomAnimationDurationMillis: Int
            = MarkerClusterStrategy<ActualMarker>.DEFAULT_ZOOM_ANIMATION_DURATION_MILLIS,
        cameraIdleDebounceMillis: Int
            = MarkerClusterStrategy<ActualMarker>.DEFAULT_CAMERA_DEBOUNCE_MILLIS,
        tileSize: Double = MarkerClusterStrategy<ActualMarker>.DEFAULT_TILE_SIZE
    )
}
```

## Constructor Parameters

- `clusterRadiusPx`
    - Type: `Double`
    - Default: `60.0`
    - Description: Screen-space radius in pixels for merging markers into a cluster.
- `minClusterSize`
    - Type: `Int`
    - Default: `2`
    - Description: Minimum number of markers required to form a cluster.
- `expandMargin`
    - Type: `Double`
    - Default: `0.2`
    - Description: Fractional expansion of the viewport bounds used during clustering.
- `clusterIconProvider`
    - Type: `(Int) -> MarkerIconProtocol`
    - Default: `MarkerClusterStrategy.defaultIconProvider`
    - Description: Closure that returns a cluster icon given the cluster count.
- `clusterIconProviderWithTurn`
    - Type: `((Int, Int) -> MarkerIconProtocol)?`
    - Default: `nil`
    - Description: Variant that also receives a turn index for animated cluster icons.
- `onClusterClick`
    - Type: `((MarkerCluster) -> Void)?`
    - Default: `nil`
    - Description: Called when the user taps a cluster marker.
- `enableZoomAnimation`
    - Type: `Bool`
    - Default: `false`
    - Description: Animates markers expanding/contracting when the zoom level changes.
- `enablePanAnimation`
    - Type: `Bool`
    - Default: `false`
    - Description: Animates marker movements when panning.
- `zoomAnimationDurationMillis`
    - Type: `Int`
    - Default: `200`
    - Description: Duration of the zoom animation in milliseconds.
- `cameraIdleDebounceMillis`
    - Type: `Int`
    - Default: `100`
    - Description: Delay in milliseconds after camera movement before reclustering.
- `tileSize`
    - Type: `Double`
    - Default: `256.0`
    - Description: Internal tile size used for projection math.

## Properties (non-init)

- `showClusterRadiusCircle` — `Bool` — `false`. When `true`, draws debug circles around each
  cluster.
- `clusterRadiusStrokeColor` — `UIColor` — `.red`
- `clusterRadiusStrokeWidth` — `Double` — `1.0`
- `clusterRadiusFillColor` — `UIColor` — `.clear`
- `debugInfos` — `[MarkerClusterDebugInfo]` — Read-only. Updated by the clustering engine with
  per-cluster debug info.
- `strategy` — `MarkerClusterStrategy<ActualMarker>` — Read-only. The current underlying
  strategy instance. Rebuilt whenever any `@Published` property changes.

## Example

```swift
@StateObject private var clusterState = MarkerClusterGroupState<GoogleMapActualMarker>(
    clusterRadiusPx: 80.0,
    minClusterSize: 3,
    showClusterRadiusCircle: true
)

GoogleMapView(state: mapState) {
    MarkerClusterGroup(state: clusterState) {
        ForArray(markerStates) { Marker(state: $0) }
    }
}
```
