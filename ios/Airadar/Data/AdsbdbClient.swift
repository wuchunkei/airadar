import Foundation

/// Free, keyless reference data — callsigns, aircraft, airlines — from
/// adsbdb.com (github.com/mrjackwills/adsbdb), a community-run mirror with no
/// stated key requirement or rate limit. Used to fill in what the app's own
/// small bundled tables don't know; the bundled ones stay the fast, offline
/// first guess for the handful of carriers they already cover.
actor AdsbdbClient {
    static let shared = AdsbdbClient()
    private static let api = "https://api.adsbdb.com/v0"

    struct AdsbdbError: LocalizedError { let message: String; var errorDescription: String? { message } }

    struct Airline: Sendable { let name: String; let icao: String; let iata: String; let country: String }

    struct Aircraft: Sendable {
        let type: String?
        let icaoType: String?
        let manufacturer: String?
        let registration: String?
        let operatorName: String?
        let photoURL: URL?
    }

    /// The ATC callsign, ICAO form (e.g. "HVN205"), for an IATA-style flight
    /// number (e.g. "VN205") — any airline adsbdb knows, not just the ~35
    /// bundled locally. Nil if adsbdb doesn't have this one.
    func icaoCallsign(forFlightNumber flightNumber: String) async throws -> String? {
        guard let dict = try await get("callsign/\(flightNumber)") as? [String: Any],
              let route = dict["flightroute"] as? [String: Any] else { return nil }
        return route["callsign_icao"] as? String
    }

    /// An aircraft's type, manufacturer, registration and a photo, from its
    /// Mode-S / ICAO24 hex — the same hex adsb.lol, airplanes.live and OpenSky
    /// all key their own data by.
    func aircraft(modeS: String) async throws -> Aircraft? {
        guard let dict = try await get("aircraft/\(modeS)") as? [String: Any],
              let a = dict["aircraft"] as? [String: Any] else { return nil }
        return Aircraft(type: a["type"] as? String, icaoType: a["icao_type"] as? String,
                        manufacturer: a["manufacturer"] as? String, registration: a["registration"] as? String,
                        operatorName: a["registered_owner"] as? String,
                        photoURL: (a["url_photo"] as? String).flatMap(URL.init(string:)))
    }

    /// An airline's name, codes and country from either its ICAO or IATA code.
    func airline(code: String) async throws -> Airline? {
        guard let array = try await get("airline/\(code)") as? [[String: Any]], let a = array.first,
              let name = a["name"] as? String, let icao = a["icao"] as? String, let iata = a["iata"] as? String else { return nil }
        return Airline(name: name, icao: icao, iata: iata, country: a["country"] as? String ?? "")
    }

    /// Every adsbdb response wraps its payload under a top-level "response" key,
    /// an object for a single result or an array for airline lookups.
    private func get(_ path: String) async throws -> Any? {
        guard let url = URL(string: "\(Self.api)/\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Airadar-iOS (personal flight tracker)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 404: return nil
        case let c: throw AdsbdbError(message: "adsbdb answered HTTP \(c).")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["response"]
    }
}
