import Foundation
import MapConductorCore

/// 1 回の再クラスタの段取り。
///
/// 早期終了の判断 → 古いマーカーの掃除 → 計画（`+Planning`）→ 反映（`+Rendering`）
/// の順に呼ぶだけで、計算そのものは持たない。前回の描画結果の読み書きも
/// ここに集めてある（ロックを跨いで食い違わないよう、まとめて取り出す）。
extension MarkerClusterStrategy {
    func renderClusters(
        cameraPosition: MapCameraPosition,
        viewport: GeoRectBounds,
        token: Int64
    ) async {
        // Check before entering semaphore to avoid blocking
        if Task.isCancelled { return }
        if token != currentToken() { return }

        await semaphore.withPermit {
            // Double-check cancellation and renderer validity after acquiring semaphore
            if Task.isCancelled { return }
            if token != currentToken() { return }
            guard rendererBox.get() != nil else {
                MCLog.marker("MarkerClusterStrategy[\(instanceId)].renderClusters aborted: rendererMissing")
                return
            }
            let expandedBounds = expandBounds(bounds: viewport, margin: expandMargin)
            let zoom = cameraPosition.zoom
            let effectiveRadiusPx = builder.effectiveClusterRadiusPx(zoom: zoom)
            let zoomChange = updateClusteringTurn(zoom: zoom)
            let turn = zoomChange.turn
            let zoomChanged = zoomChange.zoomChanged
            let snapshot = takeRenderStateSnapshot()
            let sourceStateVersionSnapshot: Int64 = {
                sourceStatesLock.lock()
                defer { sourceStatesLock.unlock() }
                return sourceStateVersion
            }()
            let cameraMoved = snapshot.renderCameraPosition
                .map { geometry.hasCameraMoved(previous: $0, current: cameraPosition) } ?? false
            let animateTransitions =
                (enableZoomAnimation && zoomChanged) ||
                (enablePanAnimation && cameraMoved)
            MCLog.marker(
                "MarkerClusterStrategy[\(instanceId)].renderClusters token=\(token) zoom=\(zoom) animate=\(animateTransitions)"
            )

            // Any effective recluster input change (zoom change / camera pan /
            // source data change / forced) collapses an open spiderfy fan,
            // matching the React SDK where every recluster collapses it. A
            // content re-attachment with unchanged inputs (e.g. the SwiftUI
            // re-render triggered by opening the fan itself) must not collapse.
            if snapshot.forced || zoomChanged || cameraMoved
                || sourceStateVersionSnapshot != snapshot.sourceStateVersion {
                await collapseSpiderfy()
            }

            if zoomChanged,
               let lastRendered = snapshot.renderCameraPosition,
               abs(zoom - lastRendered.zoom) < MarkerClusterStrategy.minZoomDeltaForRender {
                MCLog.marker(
                    "MarkerClusterStrategy[\(instanceId)].renderClusters earlyReturn token=\(token) reason=zoomDeltaTooSmall"
                )
                return
            }

            // Early return optimization: if panning and previous coverage contains current
            // viewport (and markers didn't change), no need to recalculate
            if !snapshot.forced,
               !zoomChanged,
               let coverageBounds = snapshot.coverageBounds,
               geometry.containsBounds(container: coverageBounds, target: expandedBounds),
               sourceStateVersionSnapshot == snapshot.sourceStateVersion {
                MCLog.marker(
                    "MarkerClusterStrategy[\(instanceId)].renderClusters earlyReturn token=\(token) reason=boundsContained"
                )
                renderStateLock.lock()
                lastRenderCameraPosition = cameraPosition
                renderStateLock.unlock()
                return
            }

            await cleanupStaleMarkers(currentZoom: zoom, skipClusterRemoval: animateTransitions)
            if Task.isCancelled { return }
            if token != currentToken() { return }

            // Clear cluster assignments on zoom change to force full reclustering
            if zoomChanged {
                renderStateLock.lock()
                lastClusterAssignments = [:]
                renderStateLock.unlock()
            }

            let sourceSnapshot: [MarkerState] = {
                sourceStatesLock.lock()
                defer { sourceStatesLock.unlock() }
                return Array(sourceStates.values)
            }()

            guard let partition = partitionMarkers(
                sourceSnapshot: sourceSnapshot,
                expandedBounds: expandedBounds,
                zoom: zoom,
                zoomChanged: zoomChanged,
                snapshot: snapshot,
                token: token
            ) else { return }
            MCLog.marker(
                "MarkerClusterStrategy[\(instanceId)].partition token=\(token) cached=\(partition.cachedClusterGroups.count) new=\(partition.newMarkers.count)"
            )

            guard let mergedClusters = buildMergedClusters(
                partition: partition,
                zoom: zoom,
                effectiveRadiusPx: effectiveRadiusPx,
                snapshot: snapshot,
                token: token
            ) else { return }
            assertNoDuplicateMembers(in: mergedClusters, token: token)

            guard let plan = buildPlan(
                mergedClusters: mergedClusters,
                zoom: zoom,
                effectiveRadiusPx: effectiveRadiusPx,
                turn: turn,
                token: token
            ) else { return }
            assertNoDuplicateIds(in: plan.desiredStates, token: token)

            if token != currentToken() { return }

            await applyRender(
                desiredStates: plan.desiredStates,
                token: token,
                animateTransitions: animateTransitions,
                debugInfos: plan.debugInfos,
                previousClusterMemberCenters: snapshot.clusterMemberCenters,
                nextClusterMemberCenters: plan.clusterMemberCenters
            )
            commitRenderState(
                plan: plan,
                cameraPosition: cameraPosition,
                expandedBounds: expandedBounds,
                sourceSnapshot: sourceSnapshot,
                sourceStateVersion: sourceStateVersionSnapshot,
                token: token
            )
        }
    }

    // MARK: - 前回の描画結果の読み書き

    /// 前回の描画結果をロック 1 回でまとめて取り出す。
    /// 個別に読むと、途中で別のスレッドが書き換えて食い違った組み合わせになりうる。
    private func takeRenderStateSnapshot() -> RenderStateSnapshot {
        renderStateLock.lock()
        defer { renderStateLock.unlock() }
        let forced = forceNextRender
        forceNextRender = false
        return RenderStateSnapshot(
            forced: forced,
            renderCameraPosition: lastRenderCameraPosition,
            coverageBounds: lastClusterCoverageBounds,
            assignments: lastClusterAssignments,
            clusterPositions: lastClusterPositions,
            clusterMemberCenters: lastClusterMemberCenters,
            sourceStateVersion: lastSourceStateVersion,
            sourceFingerprints: lastSourceFingerprints
        )
    }

    private func commitRenderState(
        plan: ClusterPlan,
        cameraPosition: MapCameraPosition,
        expandedBounds: GeoRectBounds,
        sourceSnapshot: [MarkerState],
        sourceStateVersion: Int64,
        token: Int64
    ) {
        renderStateLock.lock()
        lastClusterMemberCenters = plan.clusterMemberCenters
        lastClusterPositions = plan.clusterPositions
        lastClusterAssignments = plan.assignments
        lastRenderCameraPosition = cameraPosition
        lastExpandedBounds = expandedBounds
        lastClusterCoverageBounds = plan.coverageBounds.isEmpty ? nil : plan.coverageBounds
        lastSourceStateVersion = sourceStateVersion
        // Keep fingerprints for marker move invalidation.
        // (Only update the entries we saw this render to avoid scanning all markers again.)
        for state in sourceSnapshot {
            lastSourceFingerprints[state.id] = state.fingerPrint()
        }
        let renderedCount = renderedMarkerEntities.count
        renderStateLock.unlock()
        MCLog.marker(
            "MarkerClusterStrategy[\(instanceId)].renderClusters stats token=\(token) source=\(sourceStates.count) rendered=\(renderedCount) manager=\(markerManager.allEntities().count)"
        )
    }

    /// ロック 1 回で取り出した前回の描画結果。
    struct RenderStateSnapshot {
        let forced: Bool
        let renderCameraPosition: MapCameraPosition?
        let coverageBounds: GeoRectBounds?
        let assignments: [String: String]
        let clusterPositions: [String: GeoPoint]
        let clusterMemberCenters: [String: GeoPoint]
        let sourceStateVersion: Int64
        let sourceFingerprints: [String: MarkerFingerPrint]
    }

    /// ビューポート内のマーカーを再利用可否で分けた結果。
    struct MarkerPartition {
        let newMarkers: [MarkerState]
        let cachedClusterGroups: [String: [MarkerState]]
        let cachedMarkerGroups: [String: [MarkerState]]
    }

    /// 今回描くと決まった内容一式。
    struct ClusterPlan {
        let desiredStates: [MarkerState]
        let debugInfos: [MarkerClusterDebugInfo]
        let clusterMemberCenters: [String: GeoPoint]
        let clusterPositions: [String: GeoPoint]
        let assignments: [String: String]
        let coverageBounds: GeoRectBounds
    }
}
