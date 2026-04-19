# MarkerClusterDebugInfo

A value type containing debug information about a single cluster, used for visualizing cluster
boundaries during development.

## Signature

```swift
public struct MarkerClusterDebugInfo: Equatable, Hashable {
    public let id: String
    public let center: GeoPoint
    public let radiusMeters: Double
    public let count: Int
}
```

## Properties

- `id`
    - Type: `String`
    - Description: The unique identifier of this cluster.
- `center`
    - Type: `GeoPoint`
    - Description: The geographic center of the cluster.
- `radiusMeters`
    - Type: `Double`
    - Description: The cluster radius in meters at the current zoom level.
- `count`
    - Type: `Int`
    - Description: The number of markers in this cluster.
