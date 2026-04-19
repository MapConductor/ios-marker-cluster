# MarkerClusterGroup

A `MapOverlayItemProtocol` that groups nearby markers into clusters and renders them on the map.
Provide either a `MarkerClusterStrategy` or a `MarkerClusterGroupState` to configure clustering
behavior.

## Signature

```swift
public struct MarkerClusterGroup<ActualMarker>: MapOverlayItemProtocol
```

## Initializers

### With strategy and static marker list

```swift
public init(
    strategy: MarkerClusterStrategy<ActualMarker>,
    markers: [MarkerState]
)
```

### With state and static marker list

```swift
public init(
    state: MarkerClusterGroupState<ActualMarker>,
    markers: [MarkerState]
)
```

### With strategy and `@MapViewContentBuilder` content

```swift
public init(
    strategy: MarkerClusterStrategy<ActualMarker>,
    @MapViewContentBuilder content: () -> MapViewContent
)
```

### With state and `@MapViewContentBuilder` content

```swift
public init(
    state: MarkerClusterGroupState<ActualMarker>,
    @MapViewContentBuilder content: () -> MapViewContent
)
```

### With inline parameters and `@MapViewContentBuilder` content

```swift
public init(
    clusterRadiusPx: Double = MarkerClusterStrategy<ActualMarker>.DEFAULT_CLUSTER_RADIUS_PX,
    minClusterSize: Int = MarkerClusterStrategy<ActualMarker>.DEFAULT_MIN_CLUSTER_SIZE,
    expandMargin: Double = MarkerClusterStrategy<ActualMarker>.DEFAULT_EXPAND_MARGIN,
    clusterIconProvider: @escaping MarkerClusterStrategy<ActualMarker>.ClusterIconProvider
        = MarkerClusterStrategy<ActualMarker>.defaultIconProvider,
    clusterIconProviderWithTurn: MarkerClusterStrategy<ActualMarker>.ClusterIconProviderWithTurn? = nil,
    onClusterClick: ((MarkerCluster) -> Void)? = nil,
    enableZoomAnimation: Bool = false,
    enablePanAnimation: Bool = false,
    zoomAnimationDurationMillis: Int
        = MarkerClusterStrategy<ActualMarker>.DEFAULT_ZOOM_ANIMATION_DURATION_MILLIS,
    cameraIdleDebounceMillis: Int
        = MarkerClusterStrategy<ActualMarker>.DEFAULT_CAMERA_DEBOUNCE_MILLIS,
    tileSize: Double = MarkerClusterStrategy<ActualMarker>.DEFAULT_TILE_SIZE,
    @MapViewContentBuilder content: () -> MapViewContent
)
```

## Parameters

- `strategy`
    - Type: `MarkerClusterStrategy<ActualMarker>`
    - Description: A pre-configured clustering strategy.
- `state`
    - Type: `MarkerClusterGroupState<ActualMarker>`
    - Description: An observable state object that rebuilds the strategy on any change.
- `markers`
    - Type: `[MarkerState]`
    - Description: A static list of markers to cluster.
- `clusterRadiusPx`
    - Type: `Double`
    - Default: `60.0`
    - Description: Screen-space radius in pixels within which markers are merged into a cluster.
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
    - Description: Variant that also receives a turn index for animated icons.
- `onClusterClick`
    - Type: `((MarkerCluster) -> Void)?`
    - Default: `nil`
    - Description: Called when the user taps a cluster marker.
- `enableZoomAnimation`
    - Type: `Bool`
    - Default: `false`
- `enablePanAnimation`
    - Type: `Bool`
    - Default: `false`
- `zoomAnimationDurationMillis`
    - Type: `Int`
    - Default: `200`
- `cameraIdleDebounceMillis`
    - Type: `Int`
    - Default: `100`
- `tileSize`
    - Type: `Double`
    - Default: `256.0`
- `content`
    - Type: `@MapViewContentBuilder () -> MapViewContent`
    - Description: Declarative `Marker` items to cluster.

## Example

```swift
GoogleMapView(state: mapState) {
    MarkerClusterGroup<GoogleMapActualMarker>(
        clusterRadiusPx: 60,
        minClusterSize: 2,
        clusterIconProvider: { count in BitmapIcon(bitmap: makeClusterImage(count)) }
    ) {
        ForArray(markerStates) { state in
            Marker(state: state)
        }
    }
}
```
