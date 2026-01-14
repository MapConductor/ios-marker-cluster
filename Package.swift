// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mapconductor-marker-cluster",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MapConductorMarkerCluster",
            targets: ["MapConductorMarkerCluster"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MapConductor/ios-sdk-core", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MapConductorMarkerCluster",
            dependencies: [
                .product(name: "MapConductorCore", package: "ios-sdk-core"),
            ],
        ),
    ]
)
