import Foundation
import MapConductorCore

/// 待たせておく再クラスタ要求。
struct RenderRequest {
    let cameraPosition: MapCameraPosition
    let viewport: GeoRectBounds
    let token: Int64
}

/// 再クラスタ要求を 1 件だけ保持するキュー。
///
/// **意図的に 1 件しか持たない。** カメラは 1 回の操作で何十回もイベントを出すが、
/// 途中の状態を描いても一瞬で上書きされるだけなので、常に最新だけを処理すれば足りる。
///
/// android-sdk では `Channel(Channel.CONFLATED)` が同じ役割を担う。
actor RenderQueueState {
    private var pending: RenderRequest?

    func enqueue(_ request: RenderRequest) {
        pending = request
    }

    func take() -> RenderRequest? {
        let next = pending
        pending = nil
        return next
    }

    func clear() {
        pending = nil
    }
}

/// 値の解放を必ずメインスレッドで行う入れ物。
///
/// レンダラは地図 SDK のオブジェクト（UIView など）を握っている。背景スレッドで
/// 最後の参照が切れると、そこで dealloc が走って UIKit の規約を破る。
/// 差し替え・破棄のときに古い値をメインキューへ渡してから捨てることで、
/// 解放が必ずメインスレッドで起きるようにしている。
final class MainQueueReleaseBox<T> {
    private let lock = NSLock()
    private var value: T?

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T?) {
        if !Thread.isMainThread {
            MCLog.marker("MainQueueReleaseBox.set called off main thread")
        }
        let old: T?
        lock.lock()
        old = value
        value = newValue
        lock.unlock()

        guard old != nil else { return }
        DispatchQueue.main.async {
            _ = old
        }
    }

    deinit {
        let old: T?
        lock.lock()
        old = value
        value = nil
        lock.unlock()

        guard old != nil else { return }
        DispatchQueue.main.async {
            _ = old
        }
    }
}
