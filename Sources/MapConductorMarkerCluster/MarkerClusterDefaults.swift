import Combine
import Foundation
import MapConductorCore
import UIKit

let markerClusterDefaultClusterRadiusPx: Double = 90.0
let markerClusterDefaultMinClusterSize: Int = 3
let markerClusterDefaultExpandMargin: Double = 0.2
let markerClusterDefaultTileSize: Double = 256.0
let markerClusterDefaultZoomAnimationDurationMillis: Int = 300
public let markerClusterCameraDebounceMillis: Int = 100
let markerClusterMinZoomDeltaForRender: Double = 0.02
let markerClusterDefaultSpiderfyMarkerSizePx: Double = 52.0
let markerClusterDefaultSpiderfyMarkerMarginPx: Double = 8.0
let markerClusterDefaultSpiderfyLegWidth: Double = 1.5
// '#666666' in the React SDK.
let markerClusterDefaultSpiderfyLegColor = UIColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1.0)

/// Non-generic defaults shared by ``MarkerClusterStrategy`` and ``MarkerClusterGroupState``.
public enum MarkerClusterDefaults {
    public static let clusterRadiusPx: Double = markerClusterDefaultClusterRadiusPx
    public static let minClusterSize: Int = markerClusterDefaultMinClusterSize
    public static let expandMargin: Double = markerClusterDefaultExpandMargin
    public static let tileSize: Double = markerClusterDefaultTileSize
    public static let zoomAnimationDurationMillis: Int = markerClusterDefaultZoomAnimationDurationMillis
    public static let cameraIdleDebounceMillis: Int = markerClusterCameraDebounceMillis
    public static let spiderfyMarkerSizePx: Double = markerClusterDefaultSpiderfyMarkerSizePx
    public static let spiderfyMarkerMarginPx: Double = markerClusterDefaultSpiderfyMarkerMarginPx
    public static let spiderfyLegColor: UIColor = markerClusterDefaultSpiderfyLegColor
    public static let spiderfyLegWidth: Double = markerClusterDefaultSpiderfyLegWidth
    public static let iconProvider: (Int) -> MarkerIconProtocol = { count in
        DefaultMarkerIcon(label: String(count))
    }
}

/// ログの識別用に、生成ごとの通し番号を配る。
enum MarkerClusterStrategyInstanceId {
    private static let lock = NSLock()
    private static var next: Int = 0

    static func allocate() -> Int {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        return next
    }
}

/// ActualMarker に依存しない ``MarkerClusterStrategy`` の操作面。
/// ``MarkerClusterGroupState`` がジェネリクスなしで戦略を管理するために使う。
protocol MarkerClusterStrategyBase: AnyObject {
    var onBeforeAnimation: (([MarkerClusterDebugInfo]) async -> Void)? { get set }
    var debugInfoFlow: CurrentValueSubject<[MarkerClusterDebugInfo], Never> { get }
    var spiderfyLegsFlow: CurrentValueSubject<[PolylineState], Never> { get }
    func clear()
    @MainActor func forceRender()
}

extension MarkerClusterStrategy: MarkerClusterStrategyBase {}
