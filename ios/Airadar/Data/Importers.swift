import Foundation
import EventKit
import CoreLocation
import MapKit

/// A flight number and a date spotted in some text, not yet checked against anything.
struct Candidate: Hashable, Sendable {
    let flightNumber: String
    let date: String  // yyyy-MM-dd
}

/// Pulls flight numbers and dates out of a booking confirmation, a calendar event,
/// or a mail. The timetable check later throws out the pairs that never flew.
enum FlightEmailParser {
    private static let flightNumber = try! NSRegularExpression(pattern: #"\b([A-Z]{2}|[A-Z]\d|\d[A-Z])\s?(\d{1,4})\b"#)
    private static let isoDate = try! NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#)
    private static let slashDate = try! NSRegularExpression(pattern: #"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#)
    private static let namedDate = try! NSRegularExpression(pattern: #"\b(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{4})\b"#, options: .caseInsensitive)
    private static let namedDateFirst = try! NSRegularExpression(pattern: #"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{1,2}),?\s+(\d{4})\b"#, options: .caseInsensitive)
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let decoys: Set<String> = ["PNR", "ID", "NO", "REF", "TEL", "FAX", "VAT", "PO", "PIN"]

    static func candidates(_ text: String, fallbackDates: [String] = []) -> [Candidate] {
        let upper = text.uppercased()
        var dates = extractDates(text)
        if dates.isEmpty { dates = fallbackDates }
        if dates.isEmpty { return [] }
        let ns = upper as NSString
        var codes: [String] = []
        for m in flightNumber.matches(in: upper, range: NSRange(location: 0, length: ns.length)) {
            let code = ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2))
            if decoys.contains(where: { code.hasPrefix($0) }) { continue }
            // Two letters plus a bare "1" or "12" is far more often a gate or a seat.
            if code.filter(\.isNumber).count < 2 && code.count < 4 { continue }
            if !codes.contains(code) { codes.append(code) }
        }
        var out: [Candidate] = []
        for c in codes { for d in dates { let cand = Candidate(flightNumber: c, date: d); if !out.contains(cand) { out.append(cand) } } }
        return out
    }

    private static func extractDates(_ text: String) -> [String] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var found: [String] = []
        func add(_ y: Int, _ m: Int, _ d: Int) {
            guard (1...12).contains(m), (1...31).contains(d), y > 1990 else { return }
            let s = String(format: "%04d-%02d-%02d", y, m, d)
            if !found.contains(s) { found.append(s) }
        }
        for m in isoDate.matches(in: text, range: all) {
            add(Int(ns.substring(with: m.range(at: 1)))!, Int(ns.substring(with: m.range(at: 2)))!, Int(ns.substring(with: m.range(at: 3)))!)
        }
        // Day-first, matching how most of the world writes a booking date.
        for m in slashDate.matches(in: text, range: all) {
            add(Int(ns.substring(with: m.range(at: 3)))!, Int(ns.substring(with: m.range(at: 2)))!, Int(ns.substring(with: m.range(at: 1)))!)
        }
        for m in namedDate.matches(in: text, range: all) {
            let mon = months.firstIndex(of: ns.substring(with: m.range(at: 2)).lowercased().prefix(3).description) ?? -1
            add(Int(ns.substring(with: m.range(at: 3)))!, mon + 1, Int(ns.substring(with: m.range(at: 1)))!)
        }
        for m in namedDateFirst.matches(in: text, range: all) {
            let mon = months.firstIndex(of: ns.substring(with: m.range(at: 1)).lowercased().prefix(3).description) ?? -1
            add(Int(ns.substring(with: m.range(at: 3)))!, mon + 1, Int(ns.substring(with: m.range(at: 2)))!)
        }
        return found
    }
}

/// Candidates → pending trips, each checked against the server's timetable.
enum TripImporter {
    @MainActor
    static func run(_ candidates: [Candidate], progress: (Int, Int) -> Void = { _, _ in }) async -> Int {
        let distinct = Array(Set(candidates))
        let existing = FlightStore.shared.flights
        var added = 0
        for (i, c) in distinct.enumerated() {
            let already = existing.contains { $0.flightNumber == c.flightNumber && $0.departureDay == c.date }
            if !already, var f = try? await BackendClient.flight(c.flightNumber, on: c.date) {
                f.isPending = true
                // A refusal means the plan is full; the rest would be refused too.
                if !FlightStore.shared.add(f) { return added }
                added += 1
            }
            progress(i + 1, distinct.count)
        }
        return added
    }
}

/// Flights already sitting in the phone's calendars — airline apps and mail drop them there.
enum CalendarImporter {
    static func scan() async throws -> [Candidate] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-365 * 86400),
                                                end: now.addingTimeInterval(365 * 86400), calendars: nil)
        var found: [Candidate] = []
        for e in store.events(matching: predicate) {
            let text = [e.title, e.notes, e.location].compactMap { $0 }.joined(separator: "\n")
            if text.isEmpty { continue }
            let zone = e.timeZone ?? .current
            let day = LocalDateTime.from(e.startDate, in: zone).dayString
            for c in FlightEmailParser.candidates(text, fallbackDates: [day]) where !found.contains(c) { found.append(c) }
        }
        return found
    }
}

/// Reads Gmail through the REST API with a token the phone obtained itself (gmail.readonly).
enum GmailImporter {
    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    /// Mail from the last two years that mentions a flight, in the languages a booking might arrive in.
    private static let query = "newer_than:2y (flight OR itinerary OR booking OR e-ticket OR boarding OR reservation OR 航班 OR 行程 OR 机票 OR 機票 OR 登机 OR 登機 OR 預訂 OR 预订)"

    struct Progress: Sendable { let scanned: Int; let total: Int }

    static func scan(accessToken: String, progress: @Sendable (Progress) -> Void) async throws -> [Candidate] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var q = "q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&maxResults=100"
            if let pageToken { q += "&pageToken=\(pageToken)" }
            let page = try await get(accessToken, "messages?\(q)")
            for m in page["messages"] as? [[String: Any]] ?? [] { if let id = m["id"] as? String { ids.append(id) } }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil && ids.count < 1000

        var found: [Candidate] = []
        for (i, id) in ids.enumerated() {
            let message = try await get(accessToken, "messages/\(id)?format=full")
            var text = (message["snippet"] as? String ?? "") + "\n"
            if let payload = message["payload"] as? [String: Any] { collectText(payload, into: &text) }
            for c in FlightEmailParser.candidates(text) where !found.contains(c) { found.append(c) }
            progress(Progress(scanned: i + 1, total: ids.count))
        }
        return found
    }

    private static func collectText(_ part: [String: Any], into: inout String) {
        let mime = part["mimeType"] as? String ?? ""
        if let data = (part["body"] as? [String: Any])?["data"] as? String, !data.isEmpty,
           mime.hasPrefix("text/plain") || mime.hasPrefix("text/html") {
            var b64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            if let raw = Data(base64Encoded: b64), let s = String(data: raw, encoding: .utf8) {
                into += (mime.hasPrefix("text/html") ? stripHTML(s) : s) + "\n"
            }
        }
        for p in part["parts"] as? [[String: Any]] ?? [] { collectText(p, into: &into) }
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(script|style)[^>]*>.*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|</tr>|</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func get(_ token: String, _ path: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(base)/\(path)")!, timeoutInterval: 30)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw BackendClient.BackendError(message: "Gmail access was refused (HTTP \(code)). Grant access again.", code: code) }
        guard (200..<300).contains(code) else { throw BackendClient.BackendError(message: "Gmail returned HTTP \(code).", code: code) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// Somewhere to look when there are no trips to frame yet: a coarse fix if allowed,
/// else the SIM's / the phone's country, centred at a zoom that shows it.
struct Region: Sendable { let latitude: Double; let longitude: Double; let spanDegrees: Double }

enum HomeRegion {
    @MainActor
    static func find() async -> Region {
        if let fix = await coarseFix() { return fix }
        let code = Locale.current.region?.identifier ?? ""
        return countries[code] ?? Region(latitude: 20, longitude: 0, spanDegrees: 120)
    }

    @MainActor
    private static func coarseFix() async -> Region? {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus),
              let loc = manager.location else { return nil }
        return Region(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, spanDegrees: 3)
    }

    private static let countries: [String: Region] = [
        "HK": .init(latitude: 22.35, longitude: 114.15, spanDegrees: 0.5), "MO": .init(latitude: 22.19, longitude: 113.55, spanDegrees: 0.3),
        "SG": .init(latitude: 1.35, longitude: 103.82, spanDegrees: 0.5), "TW": .init(latitude: 23.7, longitude: 121.0, spanDegrees: 4),
        "CN": .init(latitude: 35.0, longitude: 105.0, spanDegrees: 40), "JP": .init(latitude: 36.5, longitude: 138.0, spanDegrees: 18),
        "KR": .init(latitude: 36.3, longitude: 127.8, spanDegrees: 6), "TH": .init(latitude: 15.0, longitude: 101.0, spanDegrees: 14),
        "VN": .init(latitude: 16.0, longitude: 107.5, spanDegrees: 18), "MY": .init(latitude: 3.5, longitude: 108.0, spanDegrees: 14),
        "ID": .init(latitude: -2.5, longitude: 118.0, spanDegrees: 40), "PH": .init(latitude: 12.5, longitude: 122.0, spanDegrees: 16),
        "IN": .init(latitude: 22.0, longitude: 79.0, spanDegrees: 34), "AE": .init(latitude: 24.3, longitude: 54.3, spanDegrees: 5),
        "AU": .init(latitude: -26.0, longitude: 134.0, spanDegrees: 45), "NZ": .init(latitude: -41.0, longitude: 173.0, spanDegrees: 16),
        "GB": .init(latitude: 54.5, longitude: -3.0, spanDegrees: 12), "FR": .init(latitude: 46.6, longitude: 2.5, spanDegrees: 12),
        "DE": .init(latitude: 51.1, longitude: 10.4, spanDegrees: 10), "IT": .init(latitude: 42.5, longitude: 12.5, spanDegrees: 12),
        "ES": .init(latitude: 40.2, longitude: -3.7, spanDegrees: 12), "US": .init(latitude: 38.5, longitude: -97.0, spanDegrees: 55),
        "CA": .init(latitude: 58.0, longitude: -96.0, spanDegrees: 70), "BR": .init(latitude: -12.0, longitude: -52.0, spanDegrees: 45),
    ]
}
