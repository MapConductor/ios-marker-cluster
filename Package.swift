// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let frameworkLibraryType: Product.Library.LibraryType? =
    ProcessInfo.processInfo.environment["MAPCONDUCTOR_BUILD_XCFRAMEWORK"] == "1" ? .dynamic : nil
let usingLocalCore = FileManager.default.fileExists(atPath: "../ios-sdk-core/Package.swift")
let coreDependency: Package.Dependency = usingLocalCore
    ? .package(path: "../ios-sdk-core")
    : .package(url: "https://github.com/MapConductor/ios-sdk-core", from: "1.0.0")

let package = Package(
    name: "mapconductor-marker-cluster",
    platforms: [
        // See ios-sdk-core/Package.swift's comment: "15.0" must not be used here.
        .iOS("15.1"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MapConductorMarkerCluster",
            type: frameworkLibraryType,
            targets: ["MapConductorMarkerCluster"]
        ),
    ],
    dependencies: [
        coreDependency,
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
