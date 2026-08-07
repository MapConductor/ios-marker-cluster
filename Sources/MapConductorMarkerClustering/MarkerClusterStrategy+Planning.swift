import Foundation
import MapConductorCore

/// マーカー集合から「今回描く内容」を組み立てる計算部分。
///
/// 前回の割り当てをできるだけ再利用するのが要点で、これが無いとパンのたびに
/// クラスタの中心が微妙に動いてちらつく。動いていないマーカーは前回の
/// クラスタに置いたまま、新しく入ってきたものだけを ``ClusterBuilder`` にかける。
///
/// 長い走査の途中でも、発行されたトークンが追い越されたら nil を返して打ち切る。
///
/// android-sdk の `ClusterPlanner.kt` / react-sdk の `ClusterPlanner.ts` に対応する。
extension MarkerClusterStrategy {
    // MARK: - 計画の組み立て

    /// 発行済みトークンが追い越されたか。長い走査の途中で打ち切るために使う。
    private func isSuperseded(_ token: Int64) -> Bool {
        Task.isCancelled || token != currentToken()
    }

    /// ビューポート内のマーカーを「前回のまま使えるもの」と「計算し直すもの」に分ける。
    ///
    /// 追い越されたら nil を返して呼び出し側を打ち切らせる。
    func partitionMarkers(
        sourceSnapshot: [MarkerState],
        expandedBounds: GeoRectBounds,
        zoom: Double,
        zoomChanged: Bool,
        snapshot: RenderStateSnapshot,
        token: Int64
    ) -> MarkerPartition? {
        var cachedMarkers: [MarkerState] = []
        var newMarkers: [MarkerState] = []

        for state in sourceSnapshot {
            if isSuperseded(token) { return nil }
            if !geometry.containsInViewport(expandedBounds, point: state.position, zoom: zoom) { continue }

            let currentFingerprint = state.fingerPrint()
            let lastFingerprint = snapshot.sourceFingerprints[state.id]
            let movedSinceLastRender =
                lastFingerprint != nil &&
                (lastFingerprint?.latitude != currentFingerprint.latitude ||
                 lastFingerprint?.longitude != currentFingerprint.longitude)

            if let lastCoverageBounds = snapshot.coverageBounds,
               !zoomChanged,
               geometry.containsInViewport(lastCoverageBounds, point: state.position, zoom: zoom),
               snapshot.assignments[state.id] != nil,
               !movedSinceLastRender {
                cachedMarkers.append(state)
            } else {
                newMarkers.append(state)
            }
        }

        var cachedClusterGroups: [String: [MarkerState]] = [:]
        var cachedMarkerGroups: [String: [MarkerState]] = [:]
        for marker in cachedMarkers {
            if let clusterId = snapshot.assignments[marker.id] {
                if clusterId.hasPrefix(clusterIdPrefix) {
                    cachedClusterGroups[clusterId, default: []].append(marker)
                } else {
                    cachedMarkerGroups[clusterId, default: []].append(marker)
                }
            } else {
                cachedMarkerGroups[marker.id, default: []].append(marker)
            }
        }

        return MarkerPartition(
            newMarkers: newMarkers,
            cachedClusterGroups: cachedClusterGroups,
            cachedMarkerGroups: cachedMarkerGroups
        )
    }

    /// 新しいマーカーをまとめ、位置が近い前回のクラスタへ吸収させる。
    ///
    /// 吸収できたものは**前回の中心をそのまま使う**。メンバーが変わっていないのに
    /// 中心だけ動くと、パンのたびにクラスタマーカーが小刻みに揺れて見えるため。
    func buildMergedClusters(
        partition: MarkerPartition,
        zoom: Double,
        effectiveRadiusPx: Double,
        snapshot: RenderStateSnapshot,
        token: Int64
    ) -> [MergedCluster]? {
        var newClustered: [ClusterCell: [MarkerState]] = [:]
        for state in partition.newMarkers {
            if isSuperseded(token) { return nil }
            let cell = builder.cellOf(position: state.position, zoom: zoom, effectiveRadiusPx: effectiveRadiusPx)
            newClustered[cell, default: []].append(state)
        }

        let newCandidates = newClustered.keys.sorted { lhs, rhs in
            if lhs.x == rhs.x { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }.compactMap { cell -> ClusterCandidate? in
            guard let members = newClustered[cell], let center = members.first?.position else { return nil }
            return ClusterCandidate(cell: cell, center: GeoPoint.from(position: center), members: members)
        }

        if isSuperseded(token) { return nil }

        let newMergedClusters = builder.mergeClusters(
            candidates: newCandidates,
            zoom: zoom,
            effectiveRadiusPx: effectiveRadiusPx
        )

        if isSuperseded(token) { return nil }

        var finalMergedClusters: [MergedCluster] = []
        var usedCachedClusters: Set<String> = []

        for newCluster in newMergedClusters {
            if isSuperseded(token) { return nil }
            var mergedWithCached = false
            let newCenter = newCluster.center

            for (cachedClusterId, cachedMembers) in partition.cachedClusterGroups {
                guard !usedCachedClusters.contains(cachedClusterId) else { continue }
                guard let cachedPosition = snapshot.clusterPositions[cachedClusterId] else { continue }

                let metersPerPixelVal = geometry.metersPerPixel(position: newCenter, zoom: zoom)
                let thresholdMeters = effectiveRadiusPx * metersPerPixelVal
                let distance = Spherical.computeDistanceBetween(newCenter, cachedPosition)

                if distance <= thresholdMeters {
                    finalMergedClusters.append(
                        MergedCluster(center: cachedPosition, members: cachedMembers + newCluster.members)
                    )
                    usedCachedClusters.insert(cachedClusterId)
                    mergedWithCached = true
                    break
                }
            }

            if !mergedWithCached {
                finalMergedClusters.append(newCluster)
            }
        }

        for (cachedClusterId, cachedMembers) in partition.cachedClusterGroups {
            guard !usedCachedClusters.contains(cachedClusterId) else { continue }
            if let cachedPosition = snapshot.clusterPositions[cachedClusterId] {
                finalMergedClusters.append(MergedCluster(center: cachedPosition, members: cachedMembers))
            }
        }

        // 素通しのマーカーは、既にどれかのクラスタに入っていないものだけ残す。
        // 同じ ID が二重に出ると、差分計算がどちらを消せばよいか決められなくなる。
        var usedMarkerIds = Set<String>()
        for merged in finalMergedClusters {
            for member in merged.members {
                usedMarkerIds.insert(member.id)
            }
        }
        for (_, cachedMembers) in partition.cachedMarkerGroups {
            let unusedMembers = cachedMembers.filter { !usedMarkerIds.contains($0.id) }
            guard !unusedMembers.isEmpty else { continue }
            guard let center = unusedMembers.first?.position else { continue }
            finalMergedClusters.append(
                MergedCluster(center: GeoPoint.from(position: center), members: unusedMembers)
            )
            for member in unusedMembers {
                usedMarkerIds.insert(member.id)
            }
        }

        return finalMergedClusters
    }

    /// まとまりごとに「クラスタにする／そのまま描く」を決め、中心と半径を確定させる。
    func buildPlan(
        mergedClusters: [MergedCluster],
        zoom: Double,
        effectiveRadiusPx: Double,
        turn: Int,
        token: Int64
    ) -> ClusterPlan? {
        var debugInfos: [MarkerClusterDebugInfo] = []
        var clusterMemberCenters: [String: GeoPoint] = [:]
        var clusterPositions: [String: GeoPoint] = [:]
        var assignments: [String: String] = [:]
        var desiredStates: [MarkerState] = []
        let coverageBounds = GeoRectBounds()

        for merged in mergedClusters {
            if isSuperseded(token) { return nil }
            guard merged.members.count >= minClusterSize else {
                merged.members.forEach { member in
                    coverageBounds.extend(point: member.position)
                    assignments[member.id] = member.id
                }
                desiredStates.append(contentsOf: merged.members)
                continue
            }

            // 凸包は重心とデバッグ表示で使い回す。全員がほぼ同じ点にいて凸包が潰れる
            // 場合はメンバー平均へ落とす（同じ会場のクラスタが最初の 1 人の位置や
            // 前回のキャッシュ位置ではなく、その会場に出るようにするため）。
            let hull = geometry.convexHullProjected(members: merged.members, zoom: zoom)
            let centroidPoint = geometry.polygonCentroidProjected(hull)
            let center: GeoPoint = centroidPoint
                .map { geometry.unprojectFromPixel(x: $0.x, y: $0.y, zoom: zoom) }
                ?? geometry.averageGeoPoints(points: merged.members.map { GeoPoint.from(position: $0.position) })

            // 中心は毎回の再クラスタで現在のメンバーから計算し直す。メンバーが
            // 変わらないパンでは同じ重心になるのでちらつかず、メンバーが変われば
            // 古いキャッシュ位置に貼り付かず本来の中心へ動く。
            let cell = builder.cellOf(position: center, zoom: zoom, effectiveRadiusPx: effectiveRadiusPx)
            let clusterId = builder.buildClusterId(cell: cell, zoom: zoom)

            let radiusMeters = geometry.calculateClusterRadiusMeters(center: center, members: merged.members)
            let cluster = MarkerCluster(
                count: merged.members.count,
                markerIds: merged.members.map { $0.id }
            )
            let hullGeoPoints: [GeoPoint] = hull.count >= 3
                ? hull.map { geometry.unprojectFromPixel(x: $0.x, y: $0.y, zoom: zoom) }
                : []
            debugInfos.append(
                MarkerClusterDebugInfo(
                    id: clusterId,
                    center: center,
                    radiusMeters: radiusMeters,
                    count: merged.members.count,
                    hullPoints: hullGeoPoints
                )
            )
            geometry.extendCoverageBounds(bounds: coverageBounds, center: center, radiusMeters: radiusMeters)
            for member in merged.members {
                clusterMemberCenters[member.id] = center
                assignments[member.id] = clusterId
            }
            clusterPositions[clusterId] = center
            desiredStates.append(makeClusterState(cluster: cluster, id: clusterId, center: center, turn: turn))
        }

        return ClusterPlan(
            desiredStates: desiredStates,
            debugInfos: debugInfos,
            clusterMemberCenters: clusterMemberCenters,
            clusterPositions: clusterPositions,
            assignments: assignments,
            coverageBounds: coverageBounds
        )
    }

    private func makeClusterState(
        cluster: MarkerCluster,
        id: String,
        center: GeoPoint,
        turn: Int
    ) -> MarkerState {
        let icon =
            clusterIconProviderWithTurn?(cluster.count, turn) ??
            clusterIconProvider(cluster.count)
        // Cluster clicks first try spiderfy (when configured & zoomed in
        // enough), then fall through to the app's onClusterClick.
        let clusterClickable = onClusterClick != nil || spiderfyMinZoom != nil
        return MarkerState(
            position: center,
            id: id,
            extra: cluster,
            icon: icon,
            animation: nil,
            clickable: clusterClickable,
            draggable: false,
            onClick: clusterClickable ? { [weak self] _ in
                guard let self else { return }
                self.handleClusterClick(cluster)
            } : nil,
            onDragStart: nil,
            onDrag: nil,
            onDragEnd: nil,
            onAnimateStart: nil,
            onAnimateEnd: nil
        )
    }

    // MARK: - 不変条件の検査（DEBUG のみ）

    /// 同じマーカーが 2 つのまとまりに入っていないか。
    /// 入っていると差分計算がどちらを消せばよいか決められず、二重描画になる。
    func assertNoDuplicateMembers(in mergedClusters: [MergedCluster], token: Int64) {
        #if DEBUG
        var allMemberIds = Set<String>()
        var duplicateMemberIds = Set<String>()
        for merged in mergedClusters {
            for member in merged.members where !allMemberIds.insert(member.id).inserted {
                duplicateMemberIds.insert(member.id)
            }
        }
        if !duplicateMemberIds.isEmpty {
            MCLog.marker(
                "MarkerClusterStrategy[\(instanceId)].WARNING token=\(token) duplicateMembersInMergedClusters=\(duplicateMemberIds)"
            )
        }
        #endif
    }

    /// 描こうとしているマーカーの ID が重複していないか。
    func assertNoDuplicateIds(in desiredStates: [MarkerState], token: Int64) {
        #if DEBUG
        var seenIds = Set<String>()
        var duplicates = Set<String>()
        for state in desiredStates where !seenIds.insert(state.id).inserted {
            duplicates.insert(state.id)
        }
        if !duplicates.isEmpty {
            MCLog.marker(
                "MarkerClusterStrategy[\(instanceId)].ERROR token=\(token) duplicateIdsInDesiredStates count=\(desiredStates.count) unique=\(seenIds.count)"
            )
            MCLog.marker("MarkerClusterStrategy[\(instanceId)].duplicateIds token=\(token) ids=\(duplicates)")
        }
        #endif
    }
}
