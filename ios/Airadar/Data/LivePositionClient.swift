import Foundation
import CoreLocation

/// Where an aircraft is right now, from community ADS-B feeds — the same
/// receivers behind the flight-tracking sites, through APIs that are meant to be
/// called. airplanes.live first, adsb.lol as the fallback; both are keyed by the
/// ATC callsign and answer within a second or two.
struct LivePosition: Sendable, Equatable {
    let coordinate: CLLocationCoordinate2D
    /// Degrees clockwise from north.
    let heading: Double
    let altitudeFeet: Int?
    let seenAt: Date

    static func == (a: LivePosition, b: LivePosition) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.seenAt == b.seenAt
    }
}

actor LivePositionClient {
    static let shared = LivePositionClient()

    private static let sources = [
        "https://api.airplanes.live/v2/callsign/",
        "https://api.adsb.lol/v2/callsign/",
    ]

    /// The latest position for a callsign, or nil when no feeder hears it.
    func position(callsign: String) async -> LivePosition? {
        let wanted = callsign.uppercased().trimmingCharacters(in: .whitespaces)
        for base in Self.sources {
            guard let url = URL(string: base + wanted) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let aircraft = body["ac"] as? [[String: Any]] else { continue }
            // Callsigns are padded to eight characters on the wire; match on the trimmed form.
            let match = aircraft.first { (($0["flight"] as? String) ?? "").trimmingCharacters(in: .whitespaces).uppercased() == wanted }
            guard let ac = match ?? aircraft.first,
                  let lat = ac["lat"] as? Double, let lon = ac["lon"] as? Double else { continue }
            let heading = (ac["track"] as? Double) ?? (ac["true_heading"] as? Double) ?? 0
            let alt: Int? = (ac["alt_baro"] as? Int) ?? (ac["alt_geom"] as? Int)
            let ageSeconds = (ac["seen"] as? Double) ?? 0
            return LivePosition(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), heading: heading,
                                altitudeFeet: alt, seenAt: Date().addingTimeInterval(-ageSeconds))
        }
        return nil
    }
}
