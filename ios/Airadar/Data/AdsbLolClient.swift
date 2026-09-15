import Foundation

/// A free, keyless mirror of live ADS-B positions — volunteer-run, no signup, no
/// rate-limit tier to buy — with noticeably better coverage over mainland China
/// than OpenSky's own crowdsourced feed. Used only for "where is it right now":
/// unlike OpenSky it keeps no history, so a flown leg's actual path still comes
/// from OpenSky; this just answers where the plane is at this moment.
actor AdsbLolClient {
    static let shared = AdsbLolClient()
    private static let api = "https://api.adsb.lol/v2"

    struct AdsbLolError: LocalizedError { let message: String; var errorDescription: String? { message } }

    struct LiveFix: Sendable {
        let lat: Double
        let lon: Double
        let headingDeg: Double?
        let altitudeFt: Int?
        let groundSpeedKt: Double?
    }

    /// The most recent reported position for an ATC callsign, or nil if no
    /// receiver currently hears it — grounded, over open ocean, out of range.
    func fetchLivePosition(callsign: String) async throws -> LiveFix? {
        let trimmed = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty else { throw AdsbLolError(message: "No ATC callsign to look up.") }
        guard let url = URL(string: "\(Self.api)/callsign/\(trimmed)") else {
            throw AdsbLolError(message: "Bad callsign for a lookup: \(trimmed)")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        // A descriptive UA, as the project's volunteers ask of anyone hitting the API.
        req.setValue("Airadar-iOS (personal flight tracker)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AdsbLolError(message: "adsb.lol answered HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aircraft = obj["ac"] as? [[String: Any]], let a = aircraft.first,
              let lat = a["lat"] as? Double, let lon = a["lon"] as? Double else { return nil }
        return LiveFix(lat: lat, lon: lon,
                        headingDeg: (a["track"] as? Double) ?? (a["true_heading"] as? Double),
                        altitudeFt: a["alt_baro"] as? Int, // a String ("ground") on the ground — nil then, not a crash
                        groundSpeedKt: a["gs"] as? Double)
    }
}
