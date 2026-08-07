import Foundation
import MapConductorCore

/// ズーム／パン時にクラスタとメンバーの間をマーカーが移動するアニメーション。
///
/// フレームごとに `onChange` + `onPostProcess` を呼ぶだけで、どのマーカーを
/// どこへ動かすかは `+Rendering` が決める。
///
/// **件数でフレームレートを落とす**のが要点。数百件を 60fps で動かすと
/// `onChange` が間に合わずカクつくので、件数に応じて 60/30/8/4fps へ落とす。
/// 動きは粗くなるが、止まって見えるよりは良い。
///
/// android-sdk の `ClusterMarkerAnimator.kt` /
/// react-sdk の `ClusterMarkerAnimator.ts` と同じ段階分け。
extension MarkerClusterStrategy {
    /// - Returns: 最後まで再生できたとき `true`。新しいカメラ更新に追い越されて
    ///   途中で止めたときは `false`（呼び出し側が後始末する）。
    @MainActor
    func animateMarkerMoves(
        moves: [AnimatedMove],
        renderer: AnyMarkerOverlayRenderer<ActualMarker>,
        durationMillis: Int,
        token: Int64
    ) async -> Bool {
        if moves.isEmpty { return true }
        var activeMoves = moves

        let targetFrameMillis = max(
            1,
            min(durationMillis, Self.animationFrameMillis(forMoveCount: activeMoves.count))
        )
        let steps = max(1, Int(ceil(Double(durationMillis) / Double(targetFrameMillis))))
        let stepMillis = steps <= 1 ? durationMillis : max(1, Int(round(Double(durationMillis) / Double(steps))))

        let moveIcons: [BitmapIcon] = activeMoves.map { $0.baseState.icon?.toBitmapIcon() ?? defaultMarkerIcon }
        for step in 1...steps {
            if token != currentToken() { return false }
            if Task.isCancelled { return false }
            let t = Double(step) / Double(steps)
            var changeParams: [MarkerOverlayChangeParams<ActualMarker>] = []
            changeParams.reserveCapacity(activeMoves.count)
            var changeEntities: [MarkerEntity<ActualMarker>] = []
            changeEntities.reserveCapacity(activeMoves.count)

            for (index, move) in activeMoves.enumerated() {
                let position = geometry.interpolatePosition(start: move.start, end: move.end, t: t)
                let nextState = move.baseState.copy(position: position)
                let prevEntity = move.entity
                let nextEntity = MarkerEntity(
                    marker: prevEntity.marker,
                    state: nextState,
                    visible: true,
                    isRendered: true
                )
                changeParams.append(
                    MarkerOverlayChangeParams(
                        current: nextEntity,
                        bitmapIcon: moveIcons[index],
                        prev: prevEntity
                    )
                )
                changeEntities.append(nextEntity)
            }

            if !changeParams.isEmpty {
                let actualMarkers = await renderer.onChange(data: changeParams)

                for (index, actualMarker) in actualMarkers.enumerated() {
                    let fallbackMarker = activeMoves[index].entity.marker
                    let updatedEntity = MarkerEntity(
                        marker: actualMarker ?? fallbackMarker,
                        state: changeEntities[index].state,
                        visible: true,
                        isRendered: true
                    )
                    markerManager.updateEntity(updatedEntity)
                    renderStateLock.lock()
                    renderedMarkerEntities[updatedEntity.state.id] = updatedEntity
                    renderStateLock.unlock()
                    activeMoves[index].entity = updatedEntity
                }

                await renderer.onPostProcess()
            }
            if step < steps {
                let nanos = UInt64(stepMillis) * 1_000_000
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
        return true
    }

    /// 件数が多いほどフレーム間隔を延ばす。
    private static func animationFrameMillis(forMoveCount count: Int) -> Int {
        switch count {
        case ..<50:
            return 16  // ~60fps
        case ..<100:
            return 33  // ~30fps
        case ..<300:
            return 125 // ~8fps
        default:
            return 250 // ~4fps
        }
    }

    /// 出発点に置いてから目的地へ動かし、消えるものは動かし終えてから消す。
    ///
    /// 新しいカメラ更新に追い越されても、この遷移に参加していたマーカーは必ず
    /// 取り下げる。ここで諦めると、消えるはずのクラスタマーカーが地図に残り続ける。
    @MainActor
    func runTransitionAnimation(
        animatedAddEntries: [AnimatedAdd],
        animatedRemoveEntries: [AnimatedRemove],
        renderer: AnyMarkerOverlayRenderer<ActualMarker>,
        token: Int64
    ) async {
        let animatedStartEntities: [MarkerEntity<ActualMarker>]
        if !animatedAddEntries.isEmpty {
            let animatedStartStates = animatedAddEntries.map { entry in
                entry.state.copy(position: entry.start)
            }
            animatedStartEntities = await addStatesToRenderer(states: animatedStartStates, renderer: renderer)
            await renderer.onPostProcess()
        } else {
            animatedStartEntities = []
        }

        var moves: [AnimatedMove] = []
        for entry in animatedAddEntries {
            guard let entity = markerManager.getEntity(entry.state.id) else { continue }
            moves.append(
                AnimatedMove(
                    id: entry.state.id,
                    start: entry.start,
                    end: GeoPoint.from(position: entry.state.position),
                    baseState: entry.state,
                    entity: entity
                )
            )
        }
        for entry in animatedRemoveEntries {
            moves.append(
                AnimatedMove(
                    id: entry.entity.state.id,
                    start: GeoPoint.from(position: entry.entity.state.position),
                    end: entry.target,
                    baseState: entry.entity.state,
                    entity: entry.entity
                )
            )
        }

        let completed = await animateMarkerMoves(
            moves: moves,
            renderer: renderer,
            durationMillis: zoomAnimationDurationMillis,
            token: token
        )

        if !animatedRemoveEntries.isEmpty {
            await removeIfStillRendered(animatedRemoveEntries.map { $0.entity }, renderer: renderer)
        }
        if !completed, !animatedStartEntities.isEmpty {
            await removeIfStillRendered(animatedStartEntities, renderer: renderer)
        }
    }

    @MainActor
    private func removeIfStillRendered(
        _ entities: [MarkerEntity<ActualMarker>],
        renderer: AnyMarkerOverlayRenderer<ActualMarker>
    ) async {
        renderStateLock.lock()
        let target = entities.filter { renderedMarkerEntities[$0.state.id] != nil }
        renderStateLock.unlock()
        guard !target.isEmpty else { return }
        await renderer.onRemove(data: target)
        forgetEntities(target)
        await renderer.onPostProcess()
    }
}
