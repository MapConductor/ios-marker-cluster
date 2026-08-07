import Foundation
import MapConductorCore

/// クラスタリング格子のセル座標。
struct ClusterCell: Hashable {
    let x: Int
    let y: Int
}

/// 格子セル 1 つ分のまとまり。``ClusterBuilder/mergeClusters(candidates:zoom:effectiveRadiusPx:)`` の入力。
struct ClusterCandidate {
    let cell: ClusterCell
    let center: GeoPoint
    let members: [MarkerState]
}

/// 近傍セルを吸収したあとのまとまり。
struct MergedCluster {
    let center: GeoPoint
    let members: [MarkerState]
}

/// 「どのマーカーを 1 つのクラスタにまとめるか」を決める部分。
///
/// 状態を持たず、渡された候補だけから結果を決める。カメラや描画の都合は
/// ``MarkerClusterStrategy`` 側にあり、ここには入れない。
///
/// android-sdk の `ClusterBuilder.kt` / react-sdk の `ClusterBuilder.ts` と同じ計算。
/// しきい値や走査順を変えるときは 3 つとも直すこと。
struct ClusterBuilder {
    let geometry: ClusterGeometry
    let clusterRadiusPx: Double

    private static let radiusReferenceZoom: Double = 10.0
    private static let radiusMinScale: Double = 0.35
    private static let radiusMinPx: Double = 18.0
    private static let maxDenseCells: Int = 4
    private static let maxDenseCandidates: Int = 50

    /// ズームに応じて実効クラスタ半径を縮める。
    ///
    /// 低ズームでは画面上の固定半径が数百 km に相当してしまい、まとめすぎに見える。
    func effectiveClusterRadiusPx(zoom: Double) -> Double {
        let scale = min(max(zoom / Self.radiusReferenceZoom, Self.radiusMinScale), 1.0)
        return max(Self.radiusMinPx, clusterRadiusPx * scale)
    }

    func buildClusterId(cell: ClusterCell, zoom: Double) -> String {
        "\(clusterIdPrefix)\(Int(zoom.rounded()))_\(cell.x)_\(cell.y)"
    }

    /// マーカー 1 件が属する格子セルを返す。
    func cellOf(position: GeoPointProtocol, zoom: Double, effectiveRadiusPx: Double) -> ClusterCell {
        let (x, y) = geometry.projectToPixel(position: position, zoom: zoom)
        return ClusterCell(
            x: Int(floor(x / effectiveRadiusPx)),
            y: Int(floor(y / effectiveRadiusPx))
        )
    }

    /// 近い候補どうしをまとめる。
    ///
    /// 連鎖的な併合（A-B が近く B-C が近いだけで A-C まで 1 つになる）を避けるため、
    /// 種となる候補の半径に入るものだけを貪欲に吸収する。
    func mergeClusters(candidates: [ClusterCandidate], zoom: Double, effectiveRadiusPx: Double) -> [MergedCluster] {
        guard !candidates.isEmpty else { return [] }

        var cellMap: [ClusterCell: ClusterCandidate] = [:]
        for candidate in candidates {
            cellMap[candidate.cell] = candidate
        }

        var merged: [MergedCluster] = []
        var visited: Set<ClusterCell> = []

        for candidate in candidates {
            let cell = candidate.cell
            guard !visited.contains(cell) else { continue }
            visited.insert(cell)

            var seedMembers = candidate.members

            // 候補は effectiveRadiusPx 幅の格子に入れてあるので、併合距離に入る
            // ものは必ず同じセルか 8 近傍のどれかにいる。
            for dx in -1...1 {
                for dy in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    let neighborCell = ClusterCell(x: cell.x + dx, y: cell.y + dy)
                    guard let neighbor = cellMap[neighborCell] else { continue }
                    guard !visited.contains(neighborCell) else { continue }

                    let metersPerPixelA = geometry.metersPerPixel(position: candidate.center, zoom: zoom)
                    let metersPerPixelB = geometry.metersPerPixel(position: neighbor.center, zoom: zoom)
                    let thresholdMeters = effectiveRadiusPx * max(metersPerPixelA, metersPerPixelB)
                    let distanceMeters = Spherical.computeDistanceBetween(candidate.center, neighbor.center)

                    if distanceMeters <= thresholdMeters {
                        visited.insert(neighborCell)
                        seedMembers.append(contentsOf: neighbor.members)
                    }
                }
            }

            let center = selectDenseCenter(members: seedMembers, zoom: zoom, effectiveRadiusPx: effectiveRadiusPx)
            merged.append(MergedCluster(center: center, members: seedMembers))
        }

        return merged
    }

    /// まとまりの中で最も密なところにいるメンバーの位置を返す。
    ///
    /// 単純な平均だと、外れ値ひとつでクラスタの見かけ上の中心が誰もいない場所へ動く。
    /// 格子で粗く数えてから上位セルの中だけを総当たりするので、メンバー数に対して線形。
    func selectDenseCenter(members: [MarkerState], zoom: Double, effectiveRadiusPx: Double) -> GeoPoint {
        guard !members.isEmpty else { return GeoPoint(latitude: 0.0, longitude: 0.0) }
        if members.count == 1 {
            return GeoPoint.from(position: members[0].position)
        }

        let points = members.map { member -> PixelPoint in
            let (x, y) = geometry.projectToPixel(position: member.position, zoom: zoom)
            return PixelPoint(member: member, x: x, y: y)
        }
        let cellSize = effectiveRadiusPx
        var cellMap: [ClusterCell: [PixelPoint]] = [:]
        for point in points {
            let key = ClusterCell(
                x: Int(floor(point.x / cellSize)),
                y: Int(floor(point.y / cellSize))
            )
            cellMap[key, default: []].append(point)
        }

        let sortedCells = cellMap.sorted { $0.value.count > $1.value.count }
        let candidates = sortedCells
            .prefix(Self.maxDenseCells)
            .flatMap { $0.value }
            .prefix(Self.maxDenseCandidates)

        let radiusSq = cellSize * cellSize
        var bestPoint = candidates.first ?? points[0]
        var bestNeighborCount = -1
        var bestTotalDistance = Double.greatestFiniteMagnitude

        for candidate in candidates {
            var neighborCount = 0
            var totalDistance = 0.0
            for dx in -1...1 {
                for dy in -1...1 {
                    let key = ClusterCell(
                        x: Int(floor(candidate.x / cellSize)) + dx,
                        y: Int(floor(candidate.y / cellSize)) + dy
                    )
                    let neighbors = cellMap[key] ?? []
                    for other in neighbors {
                        let dxp = candidate.x - other.x
                        let dyp = candidate.y - other.y
                        let distSq = dxp * dxp + dyp * dyp
                        if distSq <= radiusSq {
                            neighborCount += 1
                            totalDistance += sqrt(distSq)
                        }
                    }
                }
            }
            if neighborCount > bestNeighborCount ||
                (neighborCount == bestNeighborCount && totalDistance < bestTotalDistance) {
                bestNeighborCount = neighborCount
                bestTotalDistance = totalDistance
                bestPoint = candidate
            }
        }

        return GeoPoint.from(position: bestPoint.member.position)
    }

    private struct PixelPoint {
        let member: MarkerState
        let x: Double
        let y: Double
    }
}

/// クラスタマーカーの ID 接頭辞。個別マーカーとの区別に使う。
let clusterIdPrefix = "cluster_"
