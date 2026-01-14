# MapConductorMarkerCluster

MarkerCluster module for MapConductor iOS SDK.

This package is **standalone** and depends only on **ios-sdk-core**.

## Requirements

- iOS 15+
- Swift 5.9+
- Xcode 15+

## Installation (Swift Package Manager)

### Option 1: Add via Xcode

1. In Xcode, open **File > Add Package Dependencies...**
2. Enter this repository URL
3. Add the product **MapConductorMarkerCluster** to your target

### Option 2: Add to `Package.swift`

Add the dependency:

```swift
dependencies: [
    .package(url: "https://github.com/MapConductor/mapconductor-marker-cluster", from: "1.0.0"),
],
```

Then add `MapConductorMarkerCluster` to your target dependencies:

```
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "MapConductorMarkerCluster", package: "mapconductor-marker-cluster"),
    ]
),
```

## Usage

```swift
import MapConductorMarkerCluster
```

### Create and update a marker cluster

The MarkerCluster module provides utilities to create a marker cluster group and update it with your data.

```swift
// Replace "ActualMarker" placeholder with the type of actual Maps SDK type, such as Marker(Google Maps), Annotation(Mapkit), etc.
let clusterStrategy: MarkerClusterStrategy<GoogleMapActualMarker> = MarkerClusterStrategy<ActualMarker>(
    enableZoomAnimation: true,
    enablePanAnimation: true
)
let markers = [
    MarkerState(position: GeoPoint.fromLatLong(...),
                id: "location-1"),
    MarkerState(position: GeoPoint.fromLatLong(...),
                id: "location-2"),
    ...
    MarkerState(position: GeoPoint.fromLatLong(...),
                id: "location-n"),
]

MarkerClusterGroup(strategy: clusterStrategy) {
    for markerState in markers {
        Marker(state: markerState)
    }
}
```

> The concrete map render (Google Maps / MapLibre / MapKit) is provided by separate packages.
> This module focuses on marker cluster logic and data handling.

