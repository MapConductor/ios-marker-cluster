# MapConductor Marker Clustering

## Description

MapConductor Marker Clustering provides a marker clustering strategy for the MapConductor iOS SDK.
It automatically groups nearby markers into clusters as you zoom out, and expands them back into individual markers as you zoom in.
It works with any map implementation (Google Maps, MapLibre, MapKit, Mapbox, ArcGIS, etc.).

## Setup

https://docs-ios.mapconductor.com/setup/

------------------------------------------------------------------------

## Usage

### Basic MarkerClusterGroup

Wrap your markers with `MarkerClusterGroup` inside any `XxxMapView` content block:

```swift
let markerStates: [MarkerState] = buildMarkerList()

XxxMapView(state: mapState) {
    MarkerClusterGroup(
        state: MarkerClusterGroupState(),
        markers: markerStates
    )
}
```

### MarkerClusterGroupState

Use `MarkerClusterGroupState` to configure clustering behaviour:

```swift
@State private var clusterState = MarkerClusterGroupState(
    clusterRadiusPx: 50,
    minClusterSize: 2,
    onClusterClick: { cluster in
        // handle cluster tap
    }
)

XxxMapView(state: mapState) {
    MarkerClusterGroup(
        state: clusterState,
        markers: markerStates
    )
}
```

### Custom Cluster Icon

Provide a closure to `clusterIconProvider` to render a custom icon for each cluster:

```swift
@State private var clusterState = MarkerClusterGroupState(
    clusterIconProvider: { count in
        DefaultMarkerIcon(
            fillColor: UIColor.blue,
            label: "\(count)",
            labelTextColor: UIColor.white
        )
    }
)
```

### Additional overlays alongside a cluster group

Add extra overlays alongside the clustered markers using the `content` closure:

```swift
XxxMapView(state: mapState) {
    MarkerClusterGroup(
        state: clusterState,
        markers: markerStates
    ) {
        // additional overlays rendered alongside the cluster group
        Circle(
            center: GeoPoint(latitude: 35.6762, longitude: 139.6503),
            radiusMeters: 500
        )
    }
}
```

------------------------------------------------------------------------

## API Reference

### MarkerClusterGroupState

| Property | Type | Default | Description |
|---|---|---|---|
| `clusterRadiusPx` | `Double` | `50.0` | Pixel radius within which markers are clustered |
| `minClusterSize` | `Int` | `2` | Minimum number of markers to form a cluster |
| `clusterIconProvider` | `((Int) -> MarkerIconInterface)?` | Default circle badge | Returns an icon for the given cluster size |
| `onClusterClick` | `((MarkerCluster) -> Void)?` | `nil` | Called when a cluster marker is tapped |
| `enableZoomAnimation` | `Bool` | `false` | Animate markers on zoom change |
| `enablePanAnimation` | `Bool` | `false` | Animate markers on pan |
