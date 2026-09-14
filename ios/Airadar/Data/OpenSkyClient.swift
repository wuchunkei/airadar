import Foundation

/// Positions an aircraft actually reported over ADS-B, so a flown leg is drawn as
/// the path it took. OpenSky keys everything by the airframe's ICAO24 hex, so a leg
/// is resolved in two steps: find the flight by callsign, then ask for its track.
actor OpenSkyClient {
    static let shared = OpenSkyClient()

    private static let tokenURL = URL(string: "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token")!
    private static let api = "https://opensky-network.org/api"

    struct OpenSkyError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Positions plus the day they were flown.
    struct FetchedTrack: Sendable { let points: [TrackPoint]; let flownOn: String }

    private var token: String?
    private var tokenExpiresAt = Date.distantPast

    func fetchTrack(_ flight: Flight) async throws -> FetchedTrack {
        guard let callsign = flight.callsign else { throw OpenSkyError(message: "No ATC callsign known for \(flight.flightNumber)") }
        guard let origin = flight.departureAirport else { throw OpenSkyError(message: "Unknown departure airport \(flight.departure)") }
        guard let destination = flight.arrivalAirport else { throw OpenSkyError(message: "Unknown arrival airport \(flight.arrival)") }
        guard let scheduled = flight.departureInstant else { throw OpenSkyError(message: "No departure time for \(flight.flightNumber)") }
        let bearer = try await accessToken()

        switch flight.phase {
        case .inProgress:
            // Airborne now: the flights endpoints only list finished flights; look at live state vectors.
            guard let icao24 = try await findAirborne(bearer, callsign, origin, destination) else {
                throw OpenSkyError(message: "\(callsign) is not in OpenSky's live picture right now. Either no receiver can hear it, or it is not actually in the air.")
            }
            return FetchedTrack(points: try await fetchPath(bearer, icao24, at: 0),
                                flownOn: LocalDateTime.from(Date(), in: origin.zone).dayString)

        case .past, .upcoming:
            let days: [Date] = flight.phase == .past ? [scheduled]
                : (1...7).map { min(scheduled, Date()).addingTimeInterval(-Double($0) * 86400) }
            var seenFromAirline: [String] = []
            var checked: [String] = []
            for day in days {
                checked.append(String(LocalDateTime.from(day, in: origin.zone).dayString.dropFirst(5)))
                if let (icao24, first, last) = try await findFlight(bearer, callsign, origin, destination, day, flight.durationMinutes, &seenFromAirline) {
                    let flownOn = LocalDateTime.from(Date(timeIntervalSince1970: TimeInterval(first)), in: origin.zone).dayString
                    return FetchedTrack(points: try await fetchPath(bearer, icao24, at: (first + last) / 2), flownOn: flownOn)
                }
            }
            let prefix = String(callsign.prefix { $0.isLetter })
            let hint = seenFromAirline.isEmpty ? " No \(prefix) flight at all was seen there."
                : " Same-airline callsigns it did see: \(seenFromAirline.prefix(6).joined(separator: ", "))."
            let whereText = "\(origin.iata) departures, \(destination.iata) arrivals and the global list"
            throw OpenSkyError(message: flight.phase == .upcoming
                ? "OpenSky has no \(callsign) in \(whereText) on \(checked.first ?? "")–\(checked.last ?? "")." + hint + " Coverage relies on volunteer receivers."
                : "OpenSky has no \(callsign) in \(whereText) on \(checked.first ?? "")." + hint + " Its history only reaches back about 30 days.")
        }
    }

    private func findFlight(_ bearer: String, _ callsign: String, _ origin: Airport, _ destination: Airport,
                            _ around: Date, _ durationMinutes: Int, _ seen: inout [String]) async throws -> (String, Int, Int)? {
        let prefix = String(callsign.prefix { $0.isLetter })
        func pick(_ body: Data?) -> (String, Int, Int)? {
            guard let body, let entries = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return nil }
            for e in entries {
                let cs = (e["callsign"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if !cs.isEmpty, cs.hasPrefix(prefix), !seen.contains(cs) { seen.append(cs) }
            }
            guard let m = entries.first(where: { Self.sameCallsign($0["callsign"] as? String ?? "", callsign) }),
                  let icao = m["icao24"] as? String, let first = m["firstSeen"] as? Int, let last = m["lastSeen"] as? Int else { return nil }
            return (icao, first, last)
        }
        let begin = Int(around.timeIntervalSince1970) - 3 * 3600
        let end = Int(around.timeIntervalSince1970) + 6 * 3600
        if let r = pick(try await getJSON("\(Self.api)/flights/departure?airport=\(origin.icao)&begin=\(begin)&end=\(end)", bearer)) { return r }
        let arrivalEnd = end + durationMinutes * 60 + 3600
        if let r = pick(try await getJSON("\(Self.api)/flights/arrival?airport=\(destination.icao)&begin=\(begin)&end=\(arrivalEnd)", bearer)) { return r }
        for offset in [-1, 1] {
            let b = Int(around.timeIntervalSince1970) + offset * 3600
            if let r = pick(try await getJSON("\(Self.api)/flights/all?begin=\(b)&end=\(b + 2 * 3600)", bearer)) { return r }
        }
        return nil
    }

    private func findAirborne(_ bearer: String, _ callsign: String, _ origin: Airport, _ destination: Airport) async throws -> String? {
        let pad = 4.0
        let url = "\(Self.api)/states/all?lamin=\(min(origin.latitude, destination.latitude) - pad)&lomin=\(min(origin.longitude, destination.longitude) - pad)&lamax=\(max(origin.latitude, destination.latitude) + pad)&lomax=\(max(origin.longitude, destination.longitude) + pad)"
        guard let body = try await getJSON(url, bearer),
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let states = obj["states"] as? [[Any]] else { return nil }
        for v in states where v.count > 1 {
            if Self.sameCallsign(v[1] as? String ?? "", callsign) { return v[0] as? String }
        }
        return nil
    }

    /// OpenSky pads callsigns to eight characters and some carriers zero-pad the number.
    private static func sameCallsign(_ seen: String, _ wanted: String) -> Bool {
        func norm(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces).uppercased()
            let letters = t.prefix { $0.isLetter }
            let digits = t.dropFirst(letters.count).prefix { $0.isNumber }
            return String(letters) + String(digits.drop { $0 == "0" })
        }
        let w = norm(wanted)
        return !w.isEmpty && norm(seen) == w
    }

    private func fetchPath(_ bearer: String, _ icao24: String, at: Int) async throws -> [TrackPoint] {
        guard let body = try await getJSON("\(Self.api)/tracks/all?icao24=\(icao24)&time=\(at)", bearer) else {
            throw OpenSkyError(message: "OpenSky matched the aircraft (\(icao24)) but kept no track for that flight.")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let path = obj["path"] as? [[Any]] else {
            throw OpenSkyError(message: "OpenSky returned a track with no positions.")
        }
        let points = path.compactMap { p -> TrackPoint? in
            guard p.count > 2, let lat = p[1] as? Double, let lon = p[2] as? Double else { return nil }
            return TrackPoint(lat: lat, lon: lon)
        }
        if points.count < 2 { throw OpenSkyError(message: "Track too short to draw.") }
        return points
    }

    private func accessToken() async throws -> String {
        if let token, Date() < tokenExpiresAt { return token }
        guard Config.isOpenSkyConfigured else { throw OpenSkyError(message: "OpenSky client credentials are not configured.") }
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=client_credentials&client_id=\(Config.openSkyClientId)&client_secret=\(Config.openSkyClientSecret)"
        req.httpBody = Data(form.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["access_token"] as? String else {
            throw OpenSkyError(message: "OpenSky refused the client credentials.")
        }
        token = t
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval((obj["expires_in"] as? Int ?? 1800) - 60))
        return t
    }

    /// nil on 404 (OpenSky's "nothing here"); an error for anything else.
    private func getJSON(_ url: String, _ bearer: String) async throws -> Data? {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 404: return nil
        case 429: throw OpenSkyError(message: "OpenSky rate limit reached for today.")
        case let c: throw OpenSkyError(message: "OpenSky answered HTTP \(c).")
        }
    }
}
