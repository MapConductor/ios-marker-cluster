import Foundation
import MapConductorCore

enum Earth {
    static let radiusMeters: Double = 6371009.0
    static let circumferenceMeters: Double = 2.0 * Double.pi * radiusMeters
}

enum Spherical {
    static func computeDistanceBetween(_ a: GeoPointProtocol, _ b: GeoPointProtocol) -> Double {
        let lat1 = a.latitude * Double.pi / 180.0
        let lat2 = b.latitude * Double.pi / 180.0
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * Double.pi / 180.0

        let sinDLat = sin(dLat / 2.0)
        let sinDLon = sin(dLon / 2.0)
        let h = sinDLat * sinDLat + cos(lat1) * cos(lat2) * sinDLon * sinDLon
        return 2.0 * Earth.radiusMeters * asin(min(1.0, sqrt(h)))
    }
}

/// 投影座標上の 1 点。凸包と重心の計算にだけ使う。
struct HullPoint {
    let x: Double
    let y: Double
}

/// クラスタリングが使う投影・境界・平均・凸包の計算。
///
/// ここにあるのは**すべて副作用のない計算**で、状態を持たない
/// （[tileSize] は投影の縮尺として受け取るだけ）。
///
/// android-sdk の `ClusterGeometry.kt` / react-sdk の `ClusterGeometry.ts` と
/// 同じ関数を同じ名前で持つ。式を変えるときは 3 つとも直すこと。
///
/// なお android は `geocell.projection` を使って投影するのに対し、iOS は
/// Web メルカトルを直接計算している（`unprojectFromPixel` があるのはそのため）。
/// これは元からの差で、この分割では変えていない。
struct ClusterGeometry {
    let tileSize: Double

    private static let degToRad: Double = Double.pi / 180.0
    private static let maxSinLat: Double = 0.9999
    private static let lowZoomThreshold: Double = 4.0
    private static let panAnimationMinDistanceMeters: Double = 1.0
    private static let cameraAngleEpsilon: Double = 1e-2
    private static let metersPerDegree: Double = 111_320.0

    func projectToPixel(position: GeoPointProtocol, zoom: Double) -> (Double, Double) {
        let scale = tileSize * pow(2.0, zoom)
        let sinLat = sin(position.latitude * Self.degToRad)
        let clamped = min(max(sinLat, -Self.maxSinLat), Self.maxSinLat)
        let x = (position.longitude + 180.0) / 360.0 * scale
        let y = (0.5 - log((1.0 + clamped) / (1.0 - clamped)) / (4.0 * Double.pi)) * scale
        return (x, y)
    }

    func unprojectFromPixel(x: Double, y: Double, zoom: Double) -> GeoPoint {
        let scale = tileSize * pow(2.0, zoom)
        let longitude = x / scale * 360.0 - 180.0
        let sinLat = tanh((0.5 - y / scale) * 2.0 * Double.pi)
        let latitude = asin(min(max(sinLat, -1.0), 1.0)) * 180.0 / Double.pi
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    func metersPerPixel(position: GeoPointProtocol, zoom: Double) -> Double {
        let scale = tileSize * pow(2.0, zoom)
        let latitudeRadians = position.latitude * Self.degToRad
        return (Earth.circumferenceMeters * cos(latitudeRadians)) / scale
    }

    func wrapLongitude(_ longitude: Double) -> Double {
        (((longitude + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0)
            .truncatingRemainder(dividingBy: 360.0)) - 180.0
    }

    func containsBounds(container: GeoRectBounds, target: GeoRectBounds) -> Bool {
        if container.isEmpty || target.isEmpty { return false }
        guard let sw = target.southWest, let ne = target.northEast else { return false }
        return container.contains(point: sw) && container.contains(point: ne)
    }

    /// 日付変更線をまたぐ表現に対応した内外判定。
    ///
    /// `GeoRectBounds.contains(point:)` は `sw.longitude > ne.longitude` の場合
    /// （日付変更線をまたぐ表現）を扱えない。さらに大きく引いた表示では実際の
    /// 可視範囲が 180 度を超えるため、低ズームでは判定を反転させて広い方を採る。
    func containsInViewport(_ bounds: GeoRectBounds?, point: GeoPointProtocol, zoom: Double) -> Bool {
        guard let bounds, !bounds.isEmpty else { return false }
        guard let sw = bounds.southWest, let ne = bounds.northEast else { return false }
        guard point.latitude >= sw.latitude && point.latitude <= ne.latitude else { return false }
        let pLon = wrapLongitude(point.longitude)
        let west = wrapLongitude(sw.longitude)
        let east = wrapLongitude(ne.longitude)
        if west <= east { return pLon >= west && pLon <= east }
        if zoom <= Self.lowZoomThreshold {
            return pLon >= east && pLon <= west
        }
        return pLon >= west || pLon <= east
    }

    func extendCoverageBounds(bounds: GeoRectBounds, center: GeoPoint, radiusMeters: Double) {
        let latPad = radiusMeters / Self.metersPerDegree
        let lonPad = radiusMeters / (Self.metersPerDegree * max(0.1, cos(center.latitude * Self.degToRad)))
        let expanded = GeoRectBounds(southWest: center, northEast: center)
            .expandedByDegrees(latPad: latPad, lonPad: lonPad)
        _ = bounds.union(other: expanded)
    }

    /// 実際の visibleRegion が取れないときのビューポート推定。
    ///
    /// 直前のビューポートの広さを 2^(zoomDelta) で伸縮し、現在のカメラ位置を中心に置き直す。
    func estimateViewport(
        zoom: Double,
        center: GeoPointProtocol,
        lastViewport: GeoRectBounds?,
        lastKnownViewportZoom: Double?
    ) -> GeoRectBounds? {
        guard let base = lastViewport, let baseZoom = lastKnownViewportZoom else { return nil }
        guard let sw = base.southWest, let ne = base.northEast else { return nil }
        let zoomDelta = baseZoom - zoom
        let scale = pow(2.0, zoomDelta)
        let wrappedCenter = GeoPoint.from(position: center.wrap())
        let centerLat = wrappedCenter.latitude
        let centerLon = wrappedCenter.longitude
        let lonSpan = sw.longitude <= ne.longitude
            ? ne.longitude - sw.longitude
            : ne.longitude + 360.0 - sw.longitude
        let halfLat = min(90.0, max(0.0, (ne.latitude - sw.latitude) / 2.0 * scale))
        let halfLon = min(180.0, max(0.0, lonSpan / 2.0 * scale))
        let result = GeoRectBounds()
        result.extend(point: GeoPoint(
            latitude: max(-90.0, min(90.0, centerLat - halfLat)),
            longitude: wrapLongitude(centerLon - halfLon)
        ))
        result.extend(point: GeoPoint(
            latitude: max(-90.0, min(90.0, centerLat + halfLat)),
            longitude: wrapLongitude(centerLon + halfLon)
        ))
        return result
    }

    func hasCameraMoved(previous: MapCameraPosition, current: MapCameraPosition) -> Bool {
        let distance = Spherical.computeDistanceBetween(previous.position, current.position)
        if distance > Self.panAnimationMinDistanceMeters { return true }
        if abs(previous.bearing - current.bearing) > Self.cameraAngleEpsilon { return true }
        return abs(previous.tilt - current.tilt) > Self.cameraAngleEpsilon
    }

    func interpolatePosition(start: GeoPointProtocol, end: GeoPointProtocol, t: Double) -> GeoPoint {
        let startAlt = start.altitude ?? 0.0
        let endAlt = end.altitude ?? 0.0
        return GeoPoint(
            latitude: start.latitude + (end.latitude - start.latitude) * t,
            longitude: start.longitude + (end.longitude - start.longitude) * t,
            altitude: startAlt + (endAlt - startAlt) * t
        )
    }

    func averageGeoPoints(points: [GeoPoint]) -> GeoPoint {
        if points.isEmpty { return GeoPoint(latitude: 0.0, longitude: 0.0) }
        var sumLat = 0.0
        var sumLon = 0.0
        for point in points {
            sumLat += point.latitude
            sumLon += point.longitude
        }
        let count = Double(points.count)
        return GeoPoint(latitude: sumLat / count, longitude: sumLon / count)
    }

    func calculateClusterRadiusMeters(center: GeoPoint, members: [MarkerState]) -> Double {
        var maxDistance = 0.0
        for state in members {
            let distance = Spherical.computeDistanceBetween(center, state.position)
            if distance > maxDistance {
                maxDistance = distance
            }
        }
        return maxDistance
    }

    /// 投影座標の凸包（Andrew's monotone chain）。3 点未満に潰れる場合は空を返す。
    func convexHullProjected(members: [MarkerState], zoom: Double) -> [HullPoint] {
        guard members.count >= 3 else { return [] }
        var points = members.map { state -> HullPoint in
            let (x, y) = projectToPixel(position: state.position, zoom: zoom)
            return HullPoint(x: x, y: y)
        }
        var seen = Set<Int64>()
        points = points.filter { p in
            let key = (Int64(p.x * 1e3) << 32) ^ Int64(p.y * 1e3)
            return seen.insert(key).inserted
        }
        guard points.count >= 3 else { return [] }
        points.sort { lhs, rhs in lhs.x != rhs.x ? lhs.x < rhs.x : lhs.y < rhs.y }
        func cross(_ o: HullPoint, _ a: HullPoint, _ b: HullPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [HullPoint] = []
        for p in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [HullPoint] = []
        for p in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        let hull = lower.dropLast() + upper.dropLast()
        return hull.count >= 3 ? Array(hull) : []
    }

    /// 靴ひも公式による多角形重心。面積が潰れている場合は頂点平均へ落とす。
    func polygonCentroidProjected(_ hull: [HullPoint]) -> HullPoint? {
        guard hull.count >= 3 else { return nil }
        var twiceArea = 0.0
        var cx = 0.0
        var cy = 0.0
        for i in hull.indices {
            let a = hull[i]
            let b = hull[(i + 1) % hull.count]
            let cross = a.x * b.y - b.x * a.y
            twiceArea += cross
            cx += (a.x + b.x) * cross
            cy += (a.y + b.y) * cross
        }
        if abs(twiceArea) < 1e-6 {
            let ax = hull.reduce(0.0) { $0 + $1.x } / Double(hull.count)
            let ay = hull.reduce(0.0) { $0 + $1.y } / Double(hull.count)
            return HullPoint(x: ax, y: ay)
        }
        cx /= 3.0 * twiceArea
        cy /= 3.0 * twiceArea
        return HullPoint(x: cx, y: cy)
    }
}
