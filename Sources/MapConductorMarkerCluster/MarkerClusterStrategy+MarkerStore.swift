import Foundation
import MapConductorCore

/// 描画済みマーカーの出し入れと記録。
///
/// `renderedMarkerEntities` は「クラスタ表示として今出しているもの」の台帳で、
/// `markerManager` とは別に持つ。spiderfy の複製は markerManager にだけ入れて
/// ここには入れないので、再クラスタの差分計算や古いマーカーの掃除が
/// 扇の背後で複製を消してしまうことがない。
///
/// android-sdk では `ClusterMarkerRenderer` が同じ台帳を持つ。
extension MarkerClusterStrategy {
    @MainActor
    func addImmediately(
        states: [MarkerState],
        renderer: AnyMarkerOverlayRenderer<ActualMarker>
    ) async {
        let addParams = states.map { state in
            MarkerOverlayAddParams(
                state: state,
                bitmapIcon: state.icon?.toBitmapIcon() ?? defaultMarkerIcon
            )
        }
        let actualMarkers = await renderer.onAdd(data: addParams)
        for (index, actualMarker) in actualMarkers.enumerated() {
            guard let actualMarker else { continue }
            let entity = MarkerEntity(
                marker: actualMarker,
                state: addParams[index].state,
                visible: true,
                isRendered: true
            )
            markerManager.registerEntity(entity)
            rememberEntity(entity)
        }
    }

    @MainActor
    func addStatesToRenderer(
        states: [MarkerState],
        renderer: AnyMarkerOverlayRenderer<ActualMarker>
    ) async -> [MarkerEntity<ActualMarker>] {
        guard !states.isEmpty else { return [] }
        if Task.isCancelled { return [] }

        let addParams = states.map { state in
            MarkerOverlayAddParams(
                state: state,
                bitmapIcon: state.icon?.toBitmapIcon() ?? defaultMarkerIcon
            )
        }
        let actualMarkers = await renderer.onAdd(data: addParams)
        var addedEntities: [MarkerEntity<ActualMarker>] = []
        for (index, actualMarker) in actualMarkers.enumerated() {
            guard let actualMarker else { continue }
            let entity = MarkerEntity(
                marker: actualMarker,
                state: addParams[index].state,
                visible: true,
                isRendered: true
            )
            markerManager.registerEntity(entity)
            rememberEntity(entity)
            addedEntities.append(entity)
        }
        return addedEntities
    }

    /// 前のズームで作られたクラスタと、元データから消えたマーカーを取り下げる。
    ///
    /// クラスタ ID にはズームが埋まっているので、ズームが変われば前のクラスタは
    /// 必ず作り直しになる。
    @MainActor
    func cleanupStaleMarkers(currentZoom: Double, skipClusterRemoval: Bool) async {
        guard let renderer = rendererBox.get() else { return }
        let currentZoomKey = Int(currentZoom.rounded())

        renderStateLock.lock()
        let allEntities = Array(renderedMarkerEntities.values)
        renderStateLock.unlock()

        sourceStatesLock.lock()
        let sourceIds = Set(sourceStates.keys)
        sourceStatesLock.unlock()

        let staleEntities = allEntities.filter { entity in
            let id = entity.state.id
            guard id.hasPrefix(clusterIdPrefix) else {
                return !sourceIds.contains(id)
            }
            if skipClusterRemoval { return false }
            // ID format: cluster_{zoomKey}_{x}_{y}
            let parts = id.split(separator: "_")
            guard parts.count >= 4, let markerZoomKey = Int(parts[1]) else { return false }
            return markerZoomKey != currentZoomKey
        }

        guard !staleEntities.isEmpty else { return }
        await renderer.onRemove(data: staleEntities)
        forgetEntities(staleEntities)
        await renderer.onPostProcess()
    }

    // MARK: - 描画済みマーカーの記録

    func rememberEntity(_ entity: MarkerEntity<ActualMarker>) {
        renderStateLock.lock()
        renderedMarkerEntities[entity.state.id] = entity
        renderStateLock.unlock()
    }

    func forgetEntities(_ entities: [MarkerEntity<ActualMarker>]) {
        renderStateLock.lock()
        for entity in entities {
            renderedMarkerEntities.removeValue(forKey: entity.state.id)
            _ = markerManager.removeEntity(entity.state.id)
        }
        renderStateLock.unlock()
    }
}
