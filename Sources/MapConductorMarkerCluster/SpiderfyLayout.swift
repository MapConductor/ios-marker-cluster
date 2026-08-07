import Foundation

/// spiderfy で開いた一時マーカーの ID 接頭辞。
let spiderfyMarkerIdPrefix = "spider_"
/// クラスタ中心と開いたメンバーをつなぐ脚ポリラインの ID 接頭辞。
let spiderfyLegIdPrefix = "spiderleg_"

/// クラスタ中心からの相対的な画面ピクセルオフセット。
struct SpiderfyOffset {
    var x: Double
    var y: Double
}

private enum SpiderfyLayoutConstants {
    static let maxIterations = 150
    static let convergenceThreshold = 0.15
    static let centerClearanceRatio = 1.3
    static let centerSpring = 0.15
    static let stepRatio = 0.6
    static let minDistance = 0.01
}

/// spiderfy で開いたメンバーを画面上のどこへ置くかを決める、力学モデルの配置計算。
///
/// クラスタの周りの等間隔な円から始めて、メンバーどうし・既に出ている他のマーカー
/// （固定の障害物）・クラスタ自身を押しのけ合わせる。同時に中心へ向かう弱いばねを
/// かけて広がりすぎを抑える。少数なら円、多いと同心の層に収束する。
///
/// 純粋な計算で、地図にもマーカーにも触らない。座標はクラスタ中心からの相対 px。
///
/// android-sdk の `SpiderfyLayout.kt` / react-sdk の `SpiderfyLayout.ts` と同じ式。
func spiderfyLayout(
    count: Int,
    markerSizePx: Double,
    marginPx: Double,
    obstacles: [SpiderfyOffset] = []
) -> [SpiderfyOffset] {
    let desired = markerSizePx + marginPx
    // クラスタ中心からの基本距離。脚線が見え、かつ離れすぎない程度
    let centerClearance = (markerSizePx * SpiderfyLayoutConstants.centerClearanceRatio).rounded() + marginPx
    var points: [SpiderfyOffset] = (0..<count).map { i in
        // 右方向(0°)基準で均等配置。2件なら左右に並び、ピン形クラスタの頭上を避けやすい
        let angle = 2.0 * Double.pi * Double(i) / Double(count)
        return SpiderfyOffset(x: cos(angle) * centerClearance, y: sin(angle) * centerClearance)
    }
    for _ in 0..<SpiderfyLayoutConstants.maxIterations {
        var maxMove = 0.0
        for i in 0..<count {
            var fx = 0.0
            var fy = 0.0
            // 展開メンバー同士の反発
            for j in 0..<count where j != i {
                let dx = points[i].x - points[j].x
                let dy = points[i].y - points[j].y
                var d = hypot(dx, dy)
                if d == 0 { d = SpiderfyLayoutConstants.minDistance }
                if d < desired {
                    let push = (desired - d) / 2.0
                    fx += (dx / d) * push
                    fy += (dy / d) * push
                }
            }
            // 周囲に既に表示されているマーカー等(固定障害物)からの反発
            for ob in obstacles {
                let dx = points[i].x - ob.x
                let dy = points[i].y - ob.y
                var d = hypot(dx, dy)
                if d == 0 { d = SpiderfyLayoutConstants.minDistance }
                if d < desired {
                    let push = desired - d
                    fx += (dx / d) * push
                    fy += (dy / d) * push
                }
            }
            var dc = hypot(points[i].x, points[i].y)
            if dc == 0 { dc = SpiderfyLayoutConstants.minDistance }
            if dc < centerClearance {
                // クラスタマーカーからの反発
                let push = centerClearance - dc
                fx += (points[i].x / dc) * push
                fy += (points[i].y / dc) * push
            } else {
                // 中心へ弱いばね(離れすぎ防止)
                let pull = (dc - centerClearance) * SpiderfyLayoutConstants.centerSpring
                fx -= (points[i].x / dc) * pull
                fy -= (points[i].y / dc) * pull
            }
            points[i].x += fx * SpiderfyLayoutConstants.stepRatio
            points[i].y += fy * SpiderfyLayoutConstants.stepRatio
            maxMove = max(maxMove, abs(fx), abs(fy))
        }
        if maxMove < SpiderfyLayoutConstants.convergenceThreshold { break }
    }
    return points
}
