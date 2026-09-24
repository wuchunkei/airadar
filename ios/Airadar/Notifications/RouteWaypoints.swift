import CoreLocation
import Foundation

/// The places a flight's route passes over, named once per flight for its Live
/// Activity: a point every quarter hour or so along the great circle, each
/// reverse-geocoded (a town, or the sea over water). Kept as fractions of the
/// way, not clock times, so a delay only shifts when each one comes up.
@MainActor
enum RouteWaypoints {
    struct Stop: Codable {
        let fraction: Double
        let name: String
    }

    private static var naming: Set<String> = []
    /// When a route last came back with no names at all — most likely the
    /// geocoder throttling a burst — so it's tried again, just not at once.
    private static var emptyAt: [String: Date] = [:]

    /// The named stops, or nil until `prepare` has run for this flight.
    static func stops(for f: Flight) -> [Stop]? {
        guard let data = UserDefaults.standard.data(forKey: key(f)) else { return nil }
        return try? JSONDecoder().decode([Stop].self, from: data)
    }

    /// The stops as the widget wants them: when the plane should be over each.
    static func waypoints(for f: Flight, departure: Date, arrival: Date) -> [FlightActivityAttributes.Waypoint] {
        let span = arrival.timeIntervalSince(departure)
        return (stops(for: f) ?? []).map { .init(at: departure + $0.fraction * span, name: $0.name) }
    }

    /// Names the route once, in the background; `done` runs when there's a result.
    /// Paced and retried, since the geocoder throttles a burst of lookups.
    static func prepare(_ f: Flight, done: @escaping @MainActor () -> Void) {
        let k = key(f)
        guard stops(for: f) == nil, !naming.contains(k),
              Date().timeIntervalSince(emptyAt[k] ?? .distantPast) > 10 * 60,
              let a = f.departureAirport?.coordinate, let b = f.arrivalAirport?.coordinate else { return }
        naming.insert(k)
        let count = min(24, max(3, f.durationMinutes / 15))
        Task { @MainActor in
            var out: [Stop] = []
            for i in 1..<count {
                let t = Double(i) / Double(count)
                let point = greatCircle(a, b, t)
                var name = await PassingLocation.describe(point)
                if name == nil {
                    try? await Task.sleep(for: .seconds(3))
                    name = await PassingLocation.describe(point)
                }
                if let name, out.last?.name != name { out.append(Stop(fraction: t, name: name)) }
                try? await Task.sleep(for: .milliseconds(1200))
            }
            naming.remove(k)
            guard !out.isEmpty else { emptyAt[k] = Date(); return }
            if let data = try? JSONEncoder().encode(out) { UserDefaults.standard.set(data, forKey: k) }
            done()
        }
    }

    private static func key(_ f: Flight) -> String { "RouteWaypoints.\(f.id)" }

    /// The point a fraction `t` of the way along the great circle from `a` to `b`.
    private static func greatCircle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        let r = Double.pi / 180
        let (la1, lo1, la2, lo2) = (a.latitude * r, a.longitude * r, b.latitude * r, b.longitude * r)
        let d = 2 * asin(sqrt(pow(sin((la2 - la1) / 2), 2) + cos(la1) * cos(la2) * pow(sin((lo2 - lo1) / 2), 2)))
        guard d > 0 else { return a }
        let wa = sin((1 - t) * d) / sin(d), wb = sin(t * d) / sin(d)
        let x = wa * cos(la1) * cos(lo1) + wb * cos(la2) * cos(lo2)
        let y = wa * cos(la1) * sin(lo1) + wb * cos(la2) * sin(lo2)
        let z = wa * sin(la1) + wb * sin(la2)
        return CLLocationCoordinate2D(latitude: atan2(z, sqrt(x * x + y * y)) / r, longitude: atan2(y, x) / r)
    }
}
