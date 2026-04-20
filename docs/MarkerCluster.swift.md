# MarkerCluster

A value type representing a single cluster of nearby markers.

## Signature

```swift
public struct MarkerCluster: Equatable, Hashable {
    public let count: Int
    public let markerIds: [String]
}
```

## Properties

- `count`
    - Type: `Int`
    - Description: The number of markers in this cluster.
- `markerIds`
    - Type: `[String]`
    - Description: The IDs of the `MarkerState` objects that belong to this cluster.
