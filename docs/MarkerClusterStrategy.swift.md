# MarkerClusterStrategy

The core clustering engine. Groups markers by screen-space proximity and provides cluster icons.

## Signature

```swift
public final class MarkerClusterStrategy<ActualMarker>: AbstractMarkerRenderingStrategy<ActualMarker> {
    public static var DEFAULT_CLUSTER_RADIUS_PX: Double { 60.0 }
    public static var DEFAULT_MIN_CLUSTER_SIZE: Int { 2 }
    public static var DEFAULT_EXPAND_MARGIN: Double { 0.2 }
    public static var DEFAULT_TILE_SIZE: Double { 256.0 }
    public static var DEFAULT_ZOOM_ANIMATION_DURATION_MILLIS: Int { 200 }
    public static var DEFAULT_CAMERA_DEBOUNCE_MILLIS: Int { 100 }

    public typealias ClusterIconProvider = (Int) -> MarkerIconProtocol
    public typealias ClusterIconProviderWithTurn = (Int, Int) -> MarkerIconProtocol

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

    public var debugInfoFlow: CurrentValueSubject<[MarkerClusterDebugInfo], Never>

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
        tileSize: Double = DEFAULT_TILE_SIZE
    )
}
```

## Constructor Parameters

- `clusterRadiusPx`
    - Type: `Double`
    - Default: `60.0`
    - Description: Screen-space radius in pixels. Markers within this radius of each other are
      merged into a single cluster.
- `minClusterSize`
    - Type: `Int`
    - Default: `2`
    - Description: Minimum number of markers that must be present to form a cluster.
- `expandMargin`
    - Type: `Double`
    - Default: `0.2`
    - Description: Fractional expansion of the viewport bounds used during clustering.
- `clusterIconProvider`
    - Type: `(Int) -> MarkerIconProtocol`
    - Default: `MarkerClusterStrategy.defaultIconProvider`
    - Description: Closure that returns the icon to display for a cluster of the given size.
- `clusterIconProviderWithTurn`
    - Type: `((Int, Int) -> MarkerIconProtocol)?`
    - Default: `nil`
    - Description: Variant that also receives a turn index for animated cluster icons.
      When non-nil, takes precedence over `clusterIconProvider`.
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
    - Description: Animates marker movements during panning.
- `zoomAnimationDurationMillis`
    - Type: `Int`
    - Default: `200`
    - Description: Duration of the zoom animation in milliseconds.
- `cameraIdleDebounceMillis`
    - Type: `Int`
    - Default: `100`
    - Description: Delay after camera movement before reclustering.
- `tileSize`
    - Type: `Double`
    - Default: `256.0`
    - Description: Internal tile size for projection math.

## Static Properties

- `DEFAULT_CLUSTER_RADIUS_PX` — `Double` — `60.0`
- `DEFAULT_MIN_CLUSTER_SIZE` — `Int` — `2`
- `DEFAULT_EXPAND_MARGIN` — `Double` — `0.2`
- `DEFAULT_TILE_SIZE` — `Double` — `256.0`
- `DEFAULT_ZOOM_ANIMATION_DURATION_MILLIS` — `Int` — `200`
- `DEFAULT_CAMERA_DEBOUNCE_MILLIS` — `Int` — `100`

## Type Aliases

- `ClusterIconProvider` — `(Int) -> MarkerIconProtocol`
- `ClusterIconProviderWithTurn` — `(Int, Int) -> MarkerIconProtocol`

## Properties

- `debugInfoFlow`
    - Type: `CurrentValueSubject<[MarkerClusterDebugInfo], Never>`
    - Description: Publishes an array of `MarkerClusterDebugInfo` values whenever clustering
      is recalculated. Subscribe to visualize cluster boundaries.

## Static Helper

- `defaultIconProvider` — `ClusterIconProvider` — Returns a `DefaultMarkerIcon` with a text
  label showing the cluster count.

## Example

```swift
let strategy = MarkerClusterStrategy<GoogleMapActualMarker>(
    clusterRadiusPx: 60.0,
    minClusterSize: 2,
    clusterIconProvider: { count in
        BitmapIcon(bitmap: makeClusterBadge(count))
    }
)

strategy.debugInfoFlow
    .sink { infos in print("Clusters: \(infos.count)") }
    .store(in: &cancellables)

GoogleMapView(state: mapState) {
    MarkerClusterGroup(strategy: strategy) {
        ForArray(markerStates) { Marker(state: $0) }
    }
}
```
