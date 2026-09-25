import CoreLocation
import Foundation

/// The cities a route passes, as airport codes along its great circle — dots on
/// the route line in the detail sheet and on the Live Activity.
///
/// Built from a bundled list of the world's large and medium airports with
/// scheduled service (OurAirports, public domain), so it's offline and instant.
/// A city with several airports reads as its IATA city code (HND, NRT → TYO);
/// a stretch with no airport near it simply has no dot. In Chinese, a stop reads
/// as its city's name instead (TYO → 东京), from a bundled table built from
/// Wikidata; a code the table lacks stays a code.
enum RouteAirports {
    struct Stop: Hashable {
        /// How far along the route, 0 at departure, 1 at arrival.
        let fraction: Double
        let code: String
        /// What the line shows: the city's name in the app's language, else the code.
        var name: String { RouteAirports.names[code] ?? code }
    }

    /// Code → city name, for the language the app is running in (only Chinese has a table).
    private static let names: [String: String] = {
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true,
              let url = Bundle.main.url(forResource: "route_names_zh", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()

    private struct Entry {
        let iata: String
        let lat: Double
        let lon: Double
        let large: Bool
        let metro: String
    }

    private static let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "route_airports", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        return rows.compactMap { r in
            guard r.count >= 5, let iata = r[0] as? String, let lat = (r[1] as? NSNumber)?.doubleValue,
                  let lon = (r[2] as? NSNumber)?.doubleValue else { return nil }
            return Entry(iata: iata, lat: lat, lon: lon, large: (r[3] as? NSNumber)?.boolValue ?? false, metro: r[4] as? String ?? "")
        }
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var memo: [String: [Stop]] = [:]

    /// At most five stops, in order along the route.
    static func along(from a: Airport, to b: Airport) -> [Stop] {
        let key = "\(a.iata)-\(b.iata)"
        lock.lock(); defer { lock.unlock() }
        if let hit = memo[key] { return hit }
        let stops = compute(from: a, to: b)
        memo[key] = stops
        return stops
    }

    private static func compute(from a: Airport, to b: Airport) -> [Stop] {
        let r = Double.pi / 180
        let p1 = unit(a.latitude * r, a.longitude * r), p2 = unit(b.latitude * r, b.longitude * r)
        let total = acos(max(-1, min(1, dot(p1, p2))))
        guard total > 0 else { return [] }
        let km = total * 6371
        // Near enough to count as "passing over": wider for a longer flight.
        let reach = max(120, min(160, km * 0.05))
        let normal = normalize(cross(p1, p2))
        let endpoints: Set<String> = [a.iata, b.iata]

        struct Candidate { let entry: Entry; let fraction: Double; let off: Double }
        var candidates: [Candidate] = []
        for e in entries where !endpoints.contains(e.iata) {
            let p = unit(e.lat * r, e.lon * r)
            let off = abs(asin(max(-1, min(1, dot(p, normal))))) * 6371
            guard off <= reach else { continue }
            // Where along the route it falls: the angle from departure to its
            // foot on the great circle, over the whole route.
            let foot = normalize(sub(p, scale(normal, dot(p, normal))))
            let along = acos(max(-1, min(1, dot(p1, foot))))
            guard dot(cross(p1, foot), normal) >= 0 else { continue }   // behind the departure
            let fraction = along / total
            // Not the departure or arrival city itself, nor its neighbour.
            guard fraction > 0.04, fraction < 0.96, along * 6371 > 90, (total - along) * 6371 > 90 else { continue }
            candidates.append(Candidate(entry: e, fraction: fraction, off: off))
        }

        // Large airports first, then the closest to the line; spaced out, one per city.
        candidates.sort { ($0.entry.large ? 0 : 1, $0.off) < ($1.entry.large ? 0 : 1, $1.off) }
        var picked: [Stop] = []
        for c in candidates where picked.count < 5 {
            let code = c.entry.metro.isEmpty ? c.entry.iata : c.entry.metro
            guard !picked.contains(where: { $0.code == code || abs($0.fraction - c.fraction) < 0.12 }) else { continue }
            picked.append(Stop(fraction: c.fraction, code: code))
        }
        return picked.sorted { $0.fraction < $1.fraction }
    }

    private typealias V = (x: Double, y: Double, z: Double)
    private static func unit(_ lat: Double, _ lon: Double) -> V { (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat)) }
    private static func dot(_ a: V, _ b: V) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func cross(_ a: V, _ b: V) -> V { (a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) }
    private static func sub(_ a: V, _ b: V) -> V { (a.x - b.x, a.y - b.y, a.z - b.z) }
    private static func scale(_ a: V, _ k: Double) -> V { (a.x * k, a.y * k, a.z * k) }
    private static func normalize(_ a: V) -> V { let n = sqrt(dot(a, a)); return n > 0 ? scale(a, 1 / n) : a }
}
