import Foundation
import MapConductorCore

/// 計画された最終形と、いま実際に出ているものの差を埋める部分。
///
/// **どれをクラスタにするかは決めない** — それは `+Clustering` の担当で、
/// ここは「今出ているもの」と「出したいもの」の差を追加・更新・削除に落とすだけ。
///
/// android-sdk の `ClusterMarkerRenderer.kt` /
/// react-sdk の `ClusterMarkerRenderer.ts` と同じ差分の取り方。
extension MarkerClusterStrategy {
    @MainActor
    func applyRender(
        desiredStates: [MarkerState],
        token: Int64,
        animateTransitions: Bool,
        debugInfos: [MarkerClusterDebugInfo],
        previousClusterMemberCenters: [String: GeoPoint],
        nextClusterMemberCenters: [String: GeoPoint]
    ) async {
        guard let renderer = rendererBox.get() else {
            MCLog.marker("MarkerClusterStrategy[\(instanceId)].applyRender skipped: rendererMissing token=\(token)")
            return
        }
        debugInfoSubject.value = debugInfos
        // Commit hull polygon updates before animation starts so polygon rendering
        // and marker animation cannot race each other.
        await onBeforeAnimation?(debugInfos)
        // Keep the current (clustered) rendering on screen until the app finishes
        // preparing the newly appearing individual markers (e.g. icon preloading).
        // A newer camera update increments the token while we wait, superseding
        // this apply so a stale cluster state is never rendered.
        if let prepareExpand {
            let appearing = desiredStates.filter { state in
                !state.id.hasPrefix(clusterIdPrefix) && markerManager.getEntity(state.id) == nil
            }
            if !appearing.isEmpty {
                await prepareExpand(appearing)
                if Task.isCancelled { return }
                if token != currentToken() { return }
            }
        }
        await updateRenderedMarkers(
            desiredStates: desiredStates,
            renderer: renderer,
            token: token,
            animateTransitions: animateTransitions,
            previousClusterMemberCenters: previousClusterMemberCenters,
            nextClusterMemberCenters: nextClusterMemberCenters
        )
    }

    @MainActor
    func updateRenderedMarkers(
        desiredStates: [MarkerState],
        renderer: AnyMarkerOverlayRenderer<ActualMarker>,
        token: Int64,
        animateTransitions: Bool,
        previousClusterMemberCenters: [String: GeoPoint],
        nextClusterMemberCenters: [String: GeoPoint]
    ) async {
        // If polygon synchronization allowed a newer camera update to arrive,
        // reconcile this result without animation instead of returning and leaving
        // the previously rendered markers on the provider map.
        if Task.isCancelled { return }
        let animationIsCurrent = token == currentToken()

        var desiredById: [String: MarkerState] = [:]
        for state in desiredStates {
            desiredById[state.id] = state
        }
        let animateZoom = animateTransitions && zoomAnimationDurationMillis > 0 && animationIsCurrent

        if !animateZoom {
            await removeOrphansBeforeDiff(desiredIds: Set(desiredById.keys), renderer: renderer)
        }

        let existingById = clusterDiffEntities()
        MCLog.marker(
            "MarkerClusterStrategy[\(instanceId)].updateRenderedMarkers token=\(token) desired=\(desiredStates.count) existing=\(existingById.count) animate=\(animateZoom)"
        )

        let removeIds = Set(existingById.keys).subtracting(desiredById.keys)
        let addStates = desiredById.filter { existingById[$0.key] == nil }.map { $0.value }
        let updateStates = desiredById.filter { existingById[$0.key] != nil }.map { $0.value }

        let animatedRemoveEntries: [AnimatedRemove] = animateZoom
            ? planAnimatedRemoves(
                removeIds: removeIds,
                existingById: existingById,
                nextClusterMemberCenters: nextClusterMemberCenters
            )
            : []
        let animatedRemoveIds = Set(animatedRemoveEntries.map { $0.entity.state.id })

        let animatedAddEntries: [AnimatedAdd] = animateZoom
            ? planAnimatedAdds(addStates: addStates, previousClusterMemberCenters: previousClusterMemberCenters)
            : []
        let animatedAddIds = Set(animatedAddEntries.map { $0.state.id })

        var didImmediateChange = false
        if await applyImmediateRemoves(ids: removeIds.subtracting(animatedRemoveIds), renderer: renderer) {
            didImmediateChange = true
        }
        let immediateAddStates = addStates.filter { !animatedAddIds.contains($0.id) }
        if !immediateAddStates.isEmpty {
            // ここは addStatesToRenderer を通さない。あちらはキャンセル済みなら
            // 何もせず戻るが、この差分反映は途中でやめると「消したが出していない」
            // 状態が残ってしまうため、最後までやり切る。
            await addImmediately(states: immediateAddStates, renderer: renderer)
            didImmediateChange = true
        }
        if await applyUpdates(updateStates: updateStates, existingById: existingById, renderer: renderer) {
            didImmediateChange = true
        }

        if didImmediateChange {
            await renderer.onPostProcess()
        }

        if !animateZoom || (animatedRemoveEntries.isEmpty && animatedAddEntries.isEmpty) {
            return
        }

        await runTransitionAnimation(
            animatedAddEntries: animatedAddEntries,
            animatedRemoveEntries: animatedRemoveEntries,
            renderer: renderer,
            token: token
        )
    }

    /// 差分の対象になっている（＝クラスタ表示が管理している）マーカー。
    ///
    /// spiderfy で開いた一時マーカーは `trySpiderfy` / `collapseSpiderfy` が
    /// 出し入れを持っているので、ここから除く。含めると再クラスタが扇の背後で
    /// 勝手に消してしまう。
    @MainActor
    private func clusterDiffEntities() -> [String: MarkerEntity<ActualMarker>] {
        var result: [String: MarkerEntity<ActualMarker>] = [:]
        for entity in markerManager.allEntities() where !entity.state.id.hasPrefix(spiderfyMarkerIdPrefix) {
            result[entity.state.id] = entity
        }
        return result
    }

    /// アニメーションしない回は、差分を取る前に「消えるもの」を先に消してしまう。
    @MainActor
    private func removeOrphansBeforeDiff(
        desiredIds: Set<String>,
        renderer: AnyMarkerOverlayRenderer<ActualMarker>
    ) async {
        let existingById = clusterDiffEntities()
        let orphanedIds = Set(existingById.keys).subtracting(desiredIds)
        renderStateLock.lock()
        let orphanedEntities = orphanedIds.compactMap { renderedMarkerEntities[$0] }
        renderStateLock.unlock()
        guard !orphanedEntities.isEmpty else { return }
        await renderer.onRemove(data: orphanedEntities)
        forgetEntities(orphanedEntities)
        await renderer.onPostProcess()
    }

    /// 消えるマーカーの行き先を決める。クラスタが消える場合は、
    /// そのメンバーたちの新しい行き先の平均へ吸い込ませる。
    @MainActor
    private func planAnimatedRemoves(
        removeIds: Set<String>,
        existingById: [String: MarkerEntity<ActualMarker>],
        nextClusterMemberCenters: [String: GeoPoint]
    ) -> [AnimatedRemove] {
        removeIds.compactMap { id in
            guard let entity = existingById[id] else { return nil }
            let target: GeoPoint
            if id.hasPrefix(clusterIdPrefix) {
                let memberIds = (entity.state.extra as? MarkerCluster)?.markerIds ?? []
                if memberIds.isEmpty { return nil }
                let memberTargets = memberIds.compactMap { nextClusterMemberCenters[$0] }
                if memberTargets.isEmpty { return nil }
                target = geometry.averageGeoPoints(points: memberTargets)
            } else {
                guard let nextTarget = nextClusterMemberCenters[id] else { return nil }
                target = nextTarget
            }
            return AnimatedRemove(entity: entity, target: target)
        }
    }

    /// 出てくるマーカーの出発点を決める。クラスタなら、前回のメンバー位置の平均から広がる。
    @MainActor
    private func planAnimatedAdds(
        addStates: [MarkerState],
        previousClusterMemberCenters: [String: GeoPoint]
    ) -> [AnimatedAdd] {
        addStates.compactMap { state in
            let start: GeoPoint
            if state.id.hasPrefix(clusterIdPrefix) {
                let memberIds = (state.extra as? MarkerCluster)?.markerIds ?? []
                if memberIds.isEmpty { return nil }
                let memberStarts = memberIds.compactMap { previousClusterMemberCenters[$0] }
                if memberStarts.isEmpty { return nil }
                start = geometry.averageGeoPoints(points: memberStarts)
            } else {
                guard let previous = previousClusterMemberCenters[state.id] else { return nil }
                start = previous
            }
            return AnimatedAdd(state: state, start: start)
        }
    }

    @MainActor
    private func applyImmediateRemoves(
        ids: Set<String>,
        renderer: AnyMarkerOverlayRenderer<ActualMarker>
    ) async -> Bool {
        guard !ids.isEmpty else { return false }
        renderStateLock.lock()
        let removedEntities = ids.compactMap { renderedMarkerEntities[$0] }
        renderStateLock.unlock()
        guard !removedEntities.isEmpty else { return false }
        await renderer.onRemove(data: removedEntities)
        forgetEntities(removedEntities)
        return true
    }

    /// 位置や見た目が変わったものだけを `onChange` に載せる（指紋が同じものは飛ばす）。
    @MainActor
    private func applyUpdates(
        updateStates: [MarkerState],
        existingById: [String: MarkerEntity<ActualMarker>],
        renderer: AnyMarkerOverlayRenderer<ActualMarker>
    ) async -> Bool {
        var changeParams: [MarkerOverlayChangeParams<ActualMarker>] = []
        var changeEntities: [MarkerEntity<ActualMarker>] = []

        for state in updateStates {
            guard let prev = existingById[state.id] else { continue }
            let nextEntity = MarkerEntity(
                marker: prev.marker,
                state: state,
                visible: true,
                isRendered: true
            )
            markerManager.registerEntity(nextEntity)

            if prev.fingerPrint == state.fingerPrint() {
                continue
            }

            changeParams.append(
                MarkerOverlayChangeParams(
                    current: nextEntity,
                    bitmapIcon: state.icon?.toBitmapIcon() ?? defaultMarkerIcon,
                    prev: prev
                )
            )
            changeEntities.append(nextEntity)
        }

        guard !changeParams.isEmpty else { return false }

        let actualMarkers = await renderer.onChange(data: changeParams)
        for (index, actualMarker) in actualMarkers.enumerated() {
            guard let actualMarker else { continue }
            let entity = MarkerEntity(
                marker: actualMarker,
                state: changeEntities[index].state,
                visible: true,
                isRendered: true
            )
            markerManager.registerEntity(entity)
            rememberEntity(entity)
        }
        return true
    }
}
