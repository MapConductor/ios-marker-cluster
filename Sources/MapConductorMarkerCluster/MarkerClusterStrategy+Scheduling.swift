import Foundation
import MapConductorCore

/// 「いつ再クラスタするか」の段取り。何をどう描くかは扱わない。
///
/// カメラは 1 回の操作で何十回もイベントを出すので、そのたびに数千件の
/// クラスタリングを走らせるわけにいかない。2 段構えで抑えている:
///
/// 1. **デバウンス** — 最後のカメライベントから `cameraIdleDebounceMillis` 静まるまで待つ。
/// 2. **1 件だけのキュー** — 待っている間に新しい要求が来たら古い方を捨てる（``RenderQueueState``）。
///
/// 発行したトークンより新しいものが出ていれば、途中の処理はいつでも打ち切ってよい。
///
/// android-sdk の `ClusterRenderScheduler.kt` /
/// react-sdk の `ClusterRenderScheduler.ts` と同じ throttle 方針。
extension MarkerClusterStrategy {
    /// ``MarkerClusterStrategy/onAdd(data:viewport:renderer:)`` の実体。
    /// Swift は extension で override できないので、本体側が薄く委譲している。
    func handleAdd<Renderer: MarkerOverlayRendererProtocol>(
        data: [MarkerState],
        viewport: GeoRectBounds,
        renderer: Renderer
    ) async -> Bool where Renderer.ActualMarker == ActualMarker {
        MCLog.marker("MarkerClusterStrategy[\(instanceId)].onAdd count=\(data.count)")
        lastViewport = viewport
        updateSourceStates(data)
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.rendererBox.set(AnyMarkerOverlayRenderer(renderer))
        }
        // A strategy can be attached after the native map is already loaded (the RN
        // extension path does this). In that case marker ingestion and the initial camera
        // callback are scheduled independently. Keep the source markers even when the
        // camera has not arrived yet; onCameraChanged will render them once it does.
        guard let cameraPosition = lastCameraPosition else { return true }
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.enqueueRender(cameraPosition: cameraPosition, viewport: viewport, token: self.currentToken())
        }
        return true
    }

    /// ``MarkerClusterStrategy/onUpdate(state:viewport:renderer:)`` の実体。
    func handleUpdate<Renderer: MarkerOverlayRendererProtocol>(
        state: MarkerState,
        viewport: GeoRectBounds,
        renderer: Renderer
    ) async -> Bool where Renderer.ActualMarker == ActualMarker {
        guard let cameraPosition = lastCameraPosition else { return true }
        MCLog.marker("MarkerClusterStrategy[\(instanceId)].onUpdate id=\(state.id)")
        sourceStatesLock.lock()
        let nextFingerprint = state.fingerPrint()
        let prevFingerprint = sourceFingerprints[state.id]
        sourceStates[state.id] = state
        sourceFingerprints[state.id] = nextFingerprint
        if prevFingerprint != nextFingerprint {
            sourceStateVersion &+= 1
        }
        sourceStatesLock.unlock()
        lastViewport = viewport
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.rendererBox.set(AnyMarkerOverlayRenderer(renderer))
            self.enqueueRender(cameraPosition: cameraPosition, viewport: viewport, token: self.currentToken())
        }
        return true
    }

    /// ``MarkerClusterStrategy/onCameraChanged(mapCameraPosition:renderer:)`` の実体。
    func handleCameraChanged<Renderer: MarkerOverlayRendererProtocol>(
        mapCameraPosition: MapCameraPosition,
        renderer: Renderer
    ) async where Renderer.ActualMarker == ActualMarker {
        lastCameraPosition = mapCameraPosition
        if let bounds = mapCameraPosition.visibleRegion?.bounds {
            lastViewport = bounds
            lastKnownViewportZoom = mapCameraPosition.zoom
        }
        MCLog.marker("MarkerClusterStrategy[\(instanceId)].onCameraChanged zoom=\(mapCameraPosition.zoom)")
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.rendererBox.set(AnyMarkerOverlayRenderer(renderer))
        }
        let token = incrementToken()
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            let nanos = UInt64(cameraIdleDebounceMillis) * 1_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            guard token == self.currentToken() else { return }
            // visibleRegion が取れないプロバイダ（ArcGIS のアニメーション中など）
            // では直前のビューポートから推定する。
            let viewport =
                mapCameraPosition.visibleRegion?.bounds ??
                self.geometry.estimateViewport(
                    zoom: mapCameraPosition.zoom,
                    center: mapCameraPosition.position,
                    lastViewport: self.lastViewport,
                    lastKnownViewportZoom: self.lastKnownViewportZoom
                ) ??
                self.lastViewport
            guard let viewport else {
                MCLog.marker("MarkerClusterStrategy[\(self.instanceId)].onCameraChanged viewportMissing")
                return
            }
            self.lastViewport = viewport
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.enqueueRender(cameraPosition: mapCameraPosition, viewport: viewport, token: token)
            }
        }
    }

    @MainActor
    func enqueueRender(
        cameraPosition: MapCameraPosition,
        viewport: GeoRectBounds,
        token: Int64
    ) {
        guard rendererBox.get() != nil else {
            MCLog.marker("MarkerClusterStrategy[\(instanceId)].enqueueRender skipped: rendererMissing token=\(token)")
            return
        }
        let request = RenderRequest(cameraPosition: cameraPosition, viewport: viewport, token: token)
        Task { [renderQueueState] in await renderQueueState.enqueue(request) }
        MCLog.marker("MarkerClusterStrategy[\(instanceId)].enqueueRender token=\(token)")
        if renderTask == nil {
            renderTask = Task { [weak self] in
                guard let self else { return }
                await self.processRenderQueue()
            }
        }
    }

    func processRenderQueue() async {
        while true {
            if Task.isCancelled {
                await MainActor.run { [weak self] in
                    self?.renderTask = nil
                }
                return
            }
            let request = await renderQueueState.take()
            guard let request else {
                await MainActor.run { [weak self] in
                    self?.renderTask = nil
                }
                return
            }

            MCLog.marker("MarkerClusterStrategy[\(instanceId)].processRenderQueue token=\(request.token)")
            await self.renderClusters(
                cameraPosition: request.cameraPosition,
                viewport: request.viewport,
                token: request.token
            )
        }
    }

    func updateSourceStates(_ data: [MarkerState]) {
        sourceStatesLock.lock()
        defer { sourceStatesLock.unlock() }
        let nextIds = Set(data.map { $0.id })
        let removedIds = Set(sourceStates.keys).subtracting(nextIds)
        var changed = false
        removedIds.forEach {
            sourceStates.removeValue(forKey: $0)
            sourceFingerprints.removeValue(forKey: $0)
            changed = true
        }
        data.forEach { state in
            let nextFingerprint = state.fingerPrint()
            let prevFingerprint = sourceFingerprints[state.id]
            if prevFingerprint != nextFingerprint {
                changed = true
            }
            sourceStates[state.id] = state
            sourceFingerprints[state.id] = nextFingerprint
        }
        if changed {
            sourceStateVersion &+= 1
        }
    }
}
