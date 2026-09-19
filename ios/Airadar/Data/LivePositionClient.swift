import Foundation
import CoreLocation

/// Where an aircraft is right now, from adsb.lol's community ADS-B feed —
/// documented, free, no approval needed, keyed by the ATC callsign, answers
/// within a second or two. airplanes.live's own API looks equivalent on paper
/// but gates every endpoint behind a manual "email us first" approval
/// (confirmed live — every call, even a bare lookup, comes back 403 until
/// then), so it isn't listed as a source here at all.
struct LivePosition: Sendable, Equatable {
    let coordinate: CLLocationCoordinate2D
    /// Degrees clockwise from north.
    let heading: Double
    let altitudeFeet: Int?
    /// The airframe's Mode-S / ICAO24 hex — what adsbdb keys its aircraft
    /// lookup by, so a type and photo can be filled in for free.
    let hex: String?
    let seenAt: Date

    static func == (a: LivePosition, b: LivePosition) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.seenAt == b.seenAt
    }
}

actor LivePositionClient {
    static let shared = LivePositionClient()

    private static let source = "https://api.adsb.lol/v2/callsign/"

    /// The latest position for a callsign, or nil when no feeder hears it.
    func position(callsign: String) async -> LivePosition? {
        let wanted = callsign.uppercased().trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: Self.source + wanted) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aircraft = body["ac"] as? [[String: Any]] else { return nil }
        // Callsigns are padded to eight characters on the wire; match on the trimmed form.
        let match = aircraft.first { (($0["flight"] as? String) ?? "").trimmingCharacters(in: .whitespaces).uppercased() == wanted }
        guard let ac = match ?? aircraft.first,
              let lat = ac["lat"] as? Double, let lon = ac["lon"] as? Double else { return nil }
        let heading = (ac["track"] as? Double) ?? (ac["true_heading"] as? Double) ?? 0
        let alt: Int? = (ac["alt_baro"] as? Int) ?? (ac["alt_geom"] as? Int)
        let ageSeconds = (ac["seen"] as? Double) ?? 0
        return LivePosition(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), heading: heading,
                            altitudeFeet: alt, hex: ac["hex"] as? String, seenAt: Date().addingTimeInterval(-ageSeconds))
    }
}
