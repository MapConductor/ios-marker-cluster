import Foundation
import MapConductorCore

/// クラスタをクリックしたときに、メンバーを扇状に開く機能（spiderfy）。
///
/// 同じ場所に複数のマーカーがあると、いくらズームしても分離できない。
/// そこで `spiderfyMinZoom` 以上でクラスタをクリックしたら、メンバーの複製を
/// 画面上で開いて脚のポリラインでつなぐ。もう一度クリックするか、
/// 再クラスタ（カメラ移動・データ変更）が起きると閉じる。
///
/// **複製で描く**のが要点。元のマーカーを動かすと、閉じたときに位置を戻す責任が
/// 発生し、途中で再クラスタが挟まると戻し損ねる。`spider_` 接頭辞の別マーカーを
/// 出し入れするだけなら、閉じる処理は「消す」だけで済む。
///
/// android-sdk の `SpiderfyController.kt` /
/// react-sdk の `SpiderfyController.ts` と同じ状態遷移。
extension MarkerClusterStrategy {
    /// Cluster clicks first try spiderfy (when configured & zoomed in enough),
    /// then fall through to the app's `onClusterClick`.
    func handleClusterClick(_ cluster: MarkerCluster) {
        guard spiderfyMinZoom != nil else {
            onClusterClick?(cluster)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.trySpiderfy(cluster: cluster) { return }
            self.onClusterClick?(cluster)
        }
    }

    /// Fans the cluster's members out around the (kept) cluster marker, or
    /// collapses the fan when the same cluster is clicked again. Returns
    /// `false` when spiderfy does not apply (disabled, below `spiderfyMinZoom`,
    /// or no members) so the click can fall through to `onClusterClick`.
    @MainActor
    func trySpiderfy(cluster: MarkerCluster) async -> Bool {
        guard let spiderfyMinZoom else { return false }
        guard let camera = lastCameraPosition, camera.zoom >= spiderfyMinZoom else { return false }

        let clusterKey = cluster.markerIds.sorted().joined(separator: ",")
        if spiderfyClusterKey == clusterKey {
            await collapseSpiderfy()
            return true
        }
        await collapseSpiderfy()

        let zoom = camera.zoom
        sourceStatesLock.lock()
        let members = cluster.markerIds.compactMap { sourceStates[$0] }
        sourceStatesLock.unlock()
        guard !members.isEmpty else { return false }

        renderStateLock.lock()
        let renderedStates = renderedMarkerEntities.values.map { $0.state }
        renderStateLock.unlock()

        // 展開・脚線の中心はクラスタマーカーの「実際の描画位置」を使う。
        // (描画位置がメンバー平均からずれていても脚線がピンの根元に刺さる)
        var centerGeo = geometry.averageGeoPoints(points: members.map { GeoPoint.from(position: $0.position) })
        for state in renderedStates {
            if let extra = state.extra as? MarkerCluster, extra == cluster {
                centerGeo = GeoPoint.from(position: state.position)
                break
            }
        }
        let (centerX, centerY) = geometry.projectToPixel(position: centerGeo, zoom: zoom)

        let offsets = spiderfyLayout(
            count: members.count,
            markerSizePx: spiderfyMarkerSizePx,
            marginPx: spiderfyMarkerMarginPx,
            obstacles: collectObstacles(
                renderedStates: renderedStates,
                centerX: centerX,
                centerY: centerY,
                zoom: zoom
            )
        )

        let (clones, legs) = makeClonesAndLegs(
            members: members,
            offsets: offsets,
            centerGeo: centerGeo,
            centerX: centerX,
            centerY: centerY,
            zoom: zoom
        )
        guard !clones.isEmpty else { return false }

        if let prepareExpand {
            // Defer rendering the fan until the app finishes preparing the
            // appearing markers (e.g. icon preloading). A collapse or a newer
            // open supersedes this pending apply via the token.
            spiderfyToken += 1
            let token = spiderfyToken
            Task { @MainActor [weak self] in
                await prepareExpand(clones)
                guard let self, self.spiderfyToken == token else { return }
                await self.applySpiderfy(clusterKey: clusterKey, clones: clones, legs: legs)
            }
        } else {
            await applySpiderfy(clusterKey: clusterKey, clones: clones, legs: legs)
        }
        return true
    }

    /// 扇の周りに既に描かれているマーカーを、動かせない障害物として集める。
    ///
    /// クリックしたクラスタ自身（中心とほぼ同位置）は除く。代わりに、ピン型
    /// アイコンの頭に相当する疑似障害物を中心の真上に置く。
    @MainActor
    private func collectObstacles(
        renderedStates: [MarkerState],
        centerX: Double,
        centerY: Double,
        zoom: Double
    ) -> [SpiderfyOffset] {
        var obstacles: [SpiderfyOffset] = []
        for state in renderedStates {
            let (px, py) = geometry.projectToPixel(position: state.position, zoom: zoom)
            let rel = SpiderfyOffset(x: px - centerX, y: py - centerY)
            let d = hypot(rel.x, rel.y)
            if d < Self.selfDistancePx || d > Self.obstacleMaxDistancePx { continue }
            obstacles.append(rel)
        }
        obstacles.append(SpiderfyOffset(x: 0, y: -(spiderfyMarkerSizePx / 2.0).rounded()))
        return obstacles
    }

    /// 開くメンバーの複製と、中心へつなぐ脚を作る。
    @MainActor
    private func makeClonesAndLegs(
        members: [MarkerState],
        offsets: [SpiderfyOffset],
        centerGeo: GeoPoint,
        centerX: Double,
        centerY: Double,
        zoom: Double
    ) -> ([MarkerState], [PolylineState]) {
        var clones: [MarkerState] = []
        var legs: [PolylineState] = []
        for (index, member) in members.enumerated() {
            let geo = geometry.unprojectFromPixel(
                x: centerX + offsets[index].x,
                y: centerY + offsets[index].y,
                zoom: zoom
            )
            clones.append(member.copy(
                id: "\(spiderfyMarkerIdPrefix)\(member.id)",
                position: geo,
                zIndex: Self.cloneZIndex
            ))
            legs.append(PolylineState(
                points: [centerGeo, geo],
                id: "\(spiderfyLegIdPrefix)\(member.id)",
                strokeColor: spiderfyLegColor,
                strokeWidth: spiderfyLegWidth,
                geodesic: false
            ))
        }
        return (clones, legs)
    }

    @MainActor
    func applySpiderfy(
        clusterKey: String,
        clones: [MarkerState],
        legs: [PolylineState]
    ) async {
        guard let renderer = rendererBox.get() else { return }
        let addParams = clones.map { state in
            MarkerOverlayAddParams(
                state: state,
                bitmapIcon: state.icon?.toBitmapIcon() ?? defaultMarkerIcon
            )
        }
        let actualMarkers = await renderer.onAdd(data: addParams)
        var entities: [MarkerEntity<ActualMarker>] = []
        for (index, actualMarker) in actualMarkers.enumerated() {
            guard let actualMarker else { continue }
            let entity = MarkerEntity(
                marker: actualMarker,
                state: addParams[index].state,
                visible: true,
                isRendered: true
            )
            // Register in markerManager so the provider's tap dispatch can resolve
            // the clone's state (member onClick still fires on the fanned marker),
            // but keep it OUT of renderedMarkerEntities so the cluster diff and
            // stale-marker cleanup never touch it.
            markerManager.registerEntity(entity)
            entities.append(entity)
        }
        await renderer.onPostProcess()
        spiderfyEntities = entities
        spiderfyClusterKey = clusterKey
        spiderfyLegsSubject.value = legs
        onSpiderfyChange?(true)
        MCLog.marker("MarkerClusterStrategy[\(instanceId)].spiderfy open count=\(entities.count)")
    }

    /// Collapses an open spiderfy fan and invalidates any apply still waiting
    /// on `prepareExpand`.
    @MainActor
    func collapseSpiderfy() async {
        spiderfyToken += 1
        guard spiderfyClusterKey != nil else { return }
        spiderfyClusterKey = nil
        let entities = spiderfyEntities
        spiderfyEntities = []
        spiderfyLegsSubject.value = []
        if !entities.isEmpty, let renderer = rendererBox.get() {
            await renderer.onRemove(data: entities)
            for entity in entities {
                _ = markerManager.removeEntity(entity.state.id)
            }
            await renderer.onPostProcess()
        }
        onSpiderfyChange?(false)
        MCLog.marker("MarkerClusterStrategy[\(instanceId)].spiderfy collapse")
    }

    private static var selfDistancePx: Double { 2.0 }
    private static var obstacleMaxDistancePx: Double { 300.0 }
    private static var cloneZIndex: Int { 2000 }
}
