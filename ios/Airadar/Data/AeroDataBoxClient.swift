import Foundation

/// Cirium-grade flight status and schedule — past, present or future, all the
/// same call — from the AeroDataBox API on RapidAPI. The free tier is 400 "API
/// units" a month and one lookup here costs 2 (verified against a live call),
/// so about 200 lookups a month: fine for looking a flight up once and keeping
/// the answer, not for polling anything on a timer.
actor AeroDataBoxClient {
    static let shared = AeroDataBoxClient()
    private static let api = "https://aerodatabox.p.rapidapi.com"

    struct AeroDataBoxError: LocalizedError { let message: String; var errorDescription: String? { message } }

    struct Leg: Codable, Sendable {
        let iata: String?
        let icao: String?
        let name: String?
        let city: String?
        let latitude: Double?
        let longitude: Double?
        let terminal: String?
        let gate: String?
        /// The schedule, and the most current estimate/actual there is — revised
        /// or runway time for a departure, predicted or actual for an arrival —
        /// falling back to the schedule itself when nothing more current exists.
        let scheduledUTC: Date?
        let currentUTC: Date?
    }

    struct FlightStatus: Codable, Sendable {
        let number: String        // "HU 7750" — AeroDataBox's own spacing
        let callsign: String?
        /// AeroDataBox's own words: "Scheduled", "Departed", "EnRoute", "Arrived",
        /// "Canceled", "Diverted", … — passed through as it comes, not remapped.
        let status: String
        let airlineName: String?
        let aircraftModel: String?
        let aircraftReg: String?
        let departure: Leg
        let arrival: Leg
    }

    /// A flight number's status on one local date — yesterday, today, or years
    /// either way — all the one call. `dateLocal` is yyyy-MM-dd, the departure
    /// airport's own calendar day. More than one result means the flight
    /// departed one local day and arrived the next.
    func fetchStatus(number: String, dateLocal: String) async throws -> [FlightStatus] {
        guard Config.isAeroDataBoxConfigured else { throw AeroDataBoxError(message: "AeroDataBox is not configured.") }
        let cleaned = number.replacingOccurrences(of: " ", with: "")
        guard let url = URL(string: "\(Self.api)/flights/number/\(cleaned)/\(dateLocal)") else {
            throw AeroDataBoxError(message: "Bad flight number for a lookup: \(number)")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(Config.aeroDataBoxKey, forHTTPHeaderField: "x-rapidapi-key")
        req.setValue("aerodatabox.p.rapidapi.com", forHTTPHeaderField: "x-rapidapi-host")
        let (data, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 404: return []
        case 429: throw AeroDataBoxError(message: "AeroDataBox's free-tier quota is used up for this month.")
        case 401, 403: throw AeroDataBoxError(message: "AeroDataBox refused the API key.")
        case let c: throw AeroDataBoxError(message: "AeroDataBox answered HTTP \(c).")
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AeroDataBoxError(message: "AeroDataBox returned something unexpected for \(number).")
        }
        return array.map(Self.parse)
    }

    private static func parse(_ obj: [String: Any]) -> FlightStatus {
        let airline = obj["airline"] as? [String: Any]
        let aircraft = obj["aircraft"] as? [String: Any]
        return FlightStatus(
            number: obj["number"] as? String ?? "",
            callsign: obj["callSign"] as? String,
            status: obj["status"] as? String ?? "Unknown",
            airlineName: airline?["name"] as? String,
            aircraftModel: aircraft?["model"] as? String,
            aircraftReg: aircraft?["reg"] as? String,
            departure: leg(obj["departure"] as? [String: Any] ?? [:], currentKeys: ["revisedTime", "runwayTime"]),
            arrival: leg(obj["arrival"] as? [String: Any] ?? [:], currentKeys: ["predictedTime", "actualTime", "runwayTime"])
        )
    }

    private static func leg(_ obj: [String: Any], currentKeys: [String]) -> Leg {
        let airport = obj["airport"] as? [String: Any]
        let location = airport?["location"] as? [String: Any]
        let scheduled = utcDate(from: (obj["scheduledTime"] as? [String: Any])?["utc"] as? String)
        var current: Date?
        for key in currentKeys {
            if let d = utcDate(from: (obj[key] as? [String: Any])?["utc"] as? String) { current = d; break }
        }
        return Leg(iata: airport?["iata"] as? String, icao: airport?["icao"] as? String,
                   name: airport?["name"] as? String, city: airport?["municipalityName"] as? String,
                   latitude: location?["lat"] as? Double, longitude: location?["lon"] as? Double,
                   terminal: obj["terminal"] as? String, gate: obj["gate"] as? String,
                   scheduledUTC: scheduled, currentUTC: current ?? scheduled)
    }

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// AeroDataBox writes UTC as "2026-09-14 15:10Z" — trim the trailing "Z"
    /// DateFormatter has no pattern letter for.
    private static func utcDate(from string: String?) -> Date? {
        guard let string, string.hasSuffix("Z") else { return nil }
        return utcFormatter.date(from: String(string.dropLast()))
    }
}

/// One flight's AeroDataBox answer, kept on disk so the free tier's ~200
/// lookups a month go to flights not yet asked about. A completed flight's
/// history never changes and a scheduled one is looked at again the next time
/// its detail sheet opens anyway, so there is never a reason to ask twice —
/// this cache is what makes that true, on this device (it does not sync to the
/// account or to other devices; each keeps its own).
@MainActor
final class AeroDataBoxCache {
    static let shared = AeroDataBoxCache()

    /// A key present but holding nil means "asked, AeroDataBox had nothing" —
    /// still worth remembering, so a flight it doesn't cover isn't asked about
    /// on every visit.
    private struct Entry: Codable { let status: AeroDataBoxClient.FlightStatus? }
    private var byFlightId: [String: Entry] = [:]

    nonisolated private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("aerodatabox-cache.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL) {
            byFlightId = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
    }

    /// Outer nil: never asked. Inner nil: asked, nothing found.
    func result(for flightId: String) -> AeroDataBoxClient.FlightStatus?? {
        byFlightId[flightId].map { $0.status }
    }

    func remember(_ flightId: String, _ status: AeroDataBoxClient.FlightStatus?) {
        byFlightId[flightId] = Entry(status: status)
        let snapshot = byFlightId
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.cacheURL, options: .atomic) }
        }
    }
}
