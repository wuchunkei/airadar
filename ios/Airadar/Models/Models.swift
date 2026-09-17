import Foundation
import SwiftUI

// One-for-one with the Android data/Models.kt, and with the server's wire shape.

struct Airport: Codable, Hashable, Identifiable, Sendable {
    let iata: String
    let icao: String
    let name: String
    let city: String
    let country: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
    let zoneId: String

    var id: String { iata }
    var zone: TimeZone { TimeZone(identifier: zoneId) ?? .gmt }
    var cityCountry: String { "\(city), \(countryCode)" }
}

enum FlightStatus: String, Codable, Sendable, CaseIterable {
    case onTime = "ON_TIME", delayed = "DELAYED", cancelled = "CANCELLED", diverted = "DIVERTED"
    case scheduled = "SCHEDULED", completed = "COMPLETED", boarding = "BOARDING"
    case departed = "DEPARTED", inFlight = "IN_FLIGHT", landed = "LANDED"

    var label: String {
        switch self {
        case .onTime: "On time"
        case .delayed: "Delayed"
        case .cancelled: "Cancelled"
        case .diverted: "Diverted"
        case .scheduled: "Scheduled"
        case .completed: "Completed"
        case .boarding: "Boarding"
        case .departed: "Departed"
        case .inFlight: "In flight"
        case .landed: "Landed"
        }
    }

    var color: Color {
        switch self {
        case .onTime, .landed, .completed: Color(red: 0.03, green: 0.48, blue: 0.33)
        case .delayed: Color(red: 0.71, green: 0.34, blue: 0.04)
        case .cancelled, .diverted: Color(red: 0.70, green: 0.15, blue: 0.12)
        case .boarding, .departed, .inFlight: Color.accentColor
        case .scheduled: Color.secondary
        }
    }
}

enum FlightPhase: Sendable { case past, inProgress, upcoming }

struct TrackPoint: Codable, Hashable, Sendable {
    let lat: Double
    let lon: Double
}

enum ShareStatus: String, Codable, Sendable {
    case pending = "PENDING", accepted = "ACCEPTED", rejected = "REJECTED", together = "TOGETHER"

    var label: String { rawValue.capitalized }

    // The server writes "accepted"; the raw values are upper-case like the Android enum.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let v = ShareStatus(rawValue: raw.uppercased()) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown share status \(raw)"))
        }
        self = v
    }

    /// The block colours: yellow, grey, green, red.
    var blockColor: Color {
        switch self {
        case .together: Color(red: 0.98, green: 0.66, blue: 0.15)
        case .pending: Color(white: 0.62)
        case .accepted: Color(red: 0.26, green: 0.63, blue: 0.28)
        case .rejected: Color(red: 0.90, green: 0.22, blue: 0.21)
        }
    }

    var rank: Int {
        switch self { case .together: 0; case .accepted: 1; case .pending: 2; case .rejected: 3 }
    }
}

struct Person: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let givenName: String
    let color: String

    var tint: Color { Color(hex: color) }
}

struct TripShare: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let person: Person
    let status: ShareStatus
}

enum FriendStatus: String, Codable, Sendable { case accepted, incoming, outgoing }

struct Friend: Codable, Hashable, Identifiable, Sendable {
    let friendshipId: String
    let person: Person
    let status: FriendStatus
    var id: String { friendshipId }
}

struct Flight: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var flightNumber: String
    var airlineName: String
    var departure: String
    var arrival: String
    var departureTerminal: String?
    var arrivalTerminal: String?
    var departureGate: String?
    var arrivalGate: String?
    /// Local clock time at each airport, as the server sends it (no zone).
    var departureTime: LocalDateTime
    var arrivalTime: LocalDateTime
    var status: FlightStatus
    var aircraft: String?
    var baggageClaim: String?
    var delayMinutes: Int = 0
    var callsign: String?
    var pnr: String?
    var isPending: Bool = false
    /// Typed in by hand because no source knew it; shown with a warning block.
    var isManual: Bool = false
    /// Set only on a flight fed this way (see FeedStatus) — nil for anything
    /// else (a real source's own record, or a manual trip edited before this
    /// existed). Never trust this at face value on its own: the server
    /// resolves it from "pending" to a real verdict before it's ever stored.
    var feedStatus: FeedStatus?
    /// Where this trip was found: "gmail" or "calendar" — nil for one the
    /// backend already knew, one typed by hand, or one pasted as plain text.
    var importedVia: String?
    /// Names found on the ticket text this trip was imported from.
    var passengers: [String] = []
    var track: [TrackPoint]?
    var trackFlownOn: String?  // yyyy-MM-dd
    var deletedAt: Date?
    var sharedBy: TripShare?
    var shares: [TripShare] = []
    var typicalDurationMinutes: Int?

    // The wire carries the track as [[lat, lon]]; everything else is one-to-one.
    enum CodingKeys: String, CodingKey {
        case id, flightNumber, airlineName, departure, arrival, departureTerminal, arrivalTerminal, departureGate, arrivalGate
        case departureTime, arrivalTime, status, aircraft, baggageClaim, delayMinutes, callsign, pnr, isPending, isManual, passengers
        case track, trackFlownOn, deletedAt, sharedBy, shares, importedVia, feedStatus
    }

    init(id: String, flightNumber: String, airlineName: String, departure: String, arrival: String,
         departureTerminal: String? = nil, arrivalTerminal: String? = nil, departureGate: String? = nil, arrivalGate: String? = nil,
         departureTime: LocalDateTime, arrivalTime: LocalDateTime, status: FlightStatus, aircraft: String? = nil,
         baggageClaim: String? = nil, delayMinutes: Int = 0, callsign: String? = nil, pnr: String? = nil, isPending: Bool = false) {
        self.id = id; self.flightNumber = flightNumber; self.airlineName = airlineName; self.departure = departure; self.arrival = arrival
        self.departureTerminal = departureTerminal; self.arrivalTerminal = arrivalTerminal; self.departureGate = departureGate
        self.arrivalGate = arrivalGate; self.departureTime = departureTime; self.arrivalTime = arrivalTime; self.status = status
        self.aircraft = aircraft; self.baggageClaim = baggageClaim; self.delayMinutes = delayMinutes; self.callsign = callsign
        self.pnr = pnr; self.isPending = isPending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        flightNumber = try c.decode(String.self, forKey: .flightNumber)
        airlineName = try c.decodeIfPresent(String.self, forKey: .airlineName) ?? ""
        departure = try c.decode(String.self, forKey: .departure)
        arrival = try c.decode(String.self, forKey: .arrival)
        departureTerminal = try c.decodeIfPresent(String.self, forKey: .departureTerminal)
        arrivalTerminal = try c.decodeIfPresent(String.self, forKey: .arrivalTerminal)
        departureGate = try c.decodeIfPresent(String.self, forKey: .departureGate)
        arrivalGate = try c.decodeIfPresent(String.self, forKey: .arrivalGate)
        departureTime = try c.decode(LocalDateTime.self, forKey: .departureTime)
        arrivalTime = try c.decode(LocalDateTime.self, forKey: .arrivalTime)
        status = (try? c.decode(FlightStatus.self, forKey: .status)) ?? .scheduled
        aircraft = try c.decodeIfPresent(String.self, forKey: .aircraft)
        baggageClaim = try c.decodeIfPresent(String.self, forKey: .baggageClaim)
        delayMinutes = try c.decodeIfPresent(Int.self, forKey: .delayMinutes) ?? 0
        callsign = try c.decodeIfPresent(String.self, forKey: .callsign)
        pnr = try c.decodeIfPresent(String.self, forKey: .pnr)
        isPending = try c.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        feedStatus = try c.decodeIfPresent(FeedStatus.self, forKey: .feedStatus)
        importedVia = try c.decodeIfPresent(String.self, forKey: .importedVia)
        passengers = try c.decodeIfPresent([String].self, forKey: .passengers) ?? []
        track = try c.decodeIfPresent([[Double]].self, forKey: .track)?.compactMap { $0.count >= 2 ? TrackPoint(lat: $0[0], lon: $0[1]) : nil }
        trackFlownOn = try c.decodeIfPresent(String.self, forKey: .trackFlownOn).map { String($0.prefix(10)) }
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        sharedBy = try c.decodeIfPresent(TripShare.self, forKey: .sharedBy)
        shares = try c.decodeIfPresent([TripShare].self, forKey: .shares) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(flightNumber, forKey: .flightNumber)
        try c.encode(airlineName, forKey: .airlineName)
        try c.encode(departure, forKey: .departure)
        try c.encode(arrival, forKey: .arrival)
        try c.encodeIfPresent(departureTerminal, forKey: .departureTerminal)
        try c.encodeIfPresent(arrivalTerminal, forKey: .arrivalTerminal)
        try c.encodeIfPresent(departureGate, forKey: .departureGate)
        try c.encodeIfPresent(arrivalGate, forKey: .arrivalGate)
        try c.encode(departureTime, forKey: .departureTime)
        try c.encode(arrivalTime, forKey: .arrivalTime)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(aircraft, forKey: .aircraft)
        try c.encodeIfPresent(baggageClaim, forKey: .baggageClaim)
        try c.encode(delayMinutes, forKey: .delayMinutes)
        try c.encodeIfPresent(callsign, forKey: .callsign)
        try c.encodeIfPresent(pnr, forKey: .pnr)
        try c.encode(isPending, forKey: .isPending)
        try c.encode(isManual, forKey: .isManual)
        try c.encodeIfPresent(feedStatus, forKey: .feedStatus)
        try c.encodeIfPresent(importedVia, forKey: .importedVia)
        if !passengers.isEmpty { try c.encode(passengers, forKey: .passengers) }
        try c.encodeIfPresent(track?.map { [$0.lat, $0.lon] }, forKey: .track)
        try c.encodeIfPresent(trackFlownOn, forKey: .trackFlownOn)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(sharedBy, forKey: .sharedBy)
        if !shares.isEmpty { try c.encode(shares, forKey: .shares) }
    }

    var departureAirport: Airport? { AirportDatabase.shared.airport(departure) }
    var arrivalAirport: Airport? { AirportDatabase.shared.airport(arrival) }

    var departureInstant: Date? { departureAirport.map { departureTime.date(in: $0.zone) } }

    /// Share of the flight done by the timetable clock, delay included: 0 before, 1 after.
    var fractionFlown: Double {
        guard let dep = departureInstant, let arr = arrivalInstant else { return 0 }
        let delay = TimeInterval(delayMinutes * 60)
        let total = arr.timeIntervalSince(dep)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(dep + delay) / total))
    }
    var arrivalInstant: Date? { arrivalAirport.map { arrivalTime.date(in: $0.zone) } }

    /// Cross-zone: an instant comparison, not a clock one.
    var phase: FlightPhase {
        let now = Date()
        guard let dep = departureInstant, let arr = arrivalInstant else {
            return departureTime.date(in: .current) < now ? .past : .upcoming
        }
        let arrival = arr.addingTimeInterval(TimeInterval(delayMinutes * 60))
        if arrival < now || status == .landed || status == .completed { return .past }
        if dep.addingTimeInterval(TimeInterval(delayMinutes * 60)) <= now { return .inProgress }
        return .upcoming
    }

    /// What the status should read once the clock alone already knows the
    /// flight is over — a source that never polls again after departure can
    /// leave a real trip stuck reading "Scheduled" long after it landed.
    /// Cancelled and diverted stay as they are; those are real outcomes worth keeping.
    var displayStatus: FlightStatus {
        guard phase == .past, status != .cancelled, status != .diverted else { return status }
        return .landed
    }

    var durationMinutes: Int {
        guard let dep = departureInstant, let arr = arrivalInstant else { return 0 }
        return max(0, Int(arr.timeIntervalSince(dep) / 60))
    }

    var distanceKm: Int {
        guard let a = departureAirport, let b = arrivalAirport else { return 0 }
        return Int(greatCircleKm(a.latitude, a.longitude, b.latitude, b.longitude).rounded())
    }

    var departureDay: String { departureTime.dayString }
}

/// A wall-clock date-time without a zone — `2026-09-21T13:25:00` on the wire.
struct LocalDateTime: Codable, Hashable, Sendable, Comparable {
    let year: Int, month: Int, day: Int, hour: Int, minute: Int

    static let wire: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    init(year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        self.year = year; self.month = month; self.day = day; self.hour = hour; self.minute = minute
    }

    init?(string: String) {
        let s = String(string.prefix(16))
        guard s.count >= 16,
              let y = Int(s.prefix(4)), let mo = Int(s.dropFirst(5).prefix(2)), let d = Int(s.dropFirst(8).prefix(2)),
              let h = Int(s.dropFirst(11).prefix(2)), let mi = Int(s.dropFirst(14).prefix(2)) else { return nil }
        self.init(year: y, month: mo, day: d, hour: h, minute: mi)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let v = LocalDateTime(string: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date-time \(raw)"))
        }
        self = v
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wireString)
    }

    var wireString: String { String(format: "%04d-%02d-%02dT%02d:%02d:00", year, month, day, hour, minute) }
    var dayString: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var clock: String { String(format: "%02d:%02d", hour, minute) }

    func date(in zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    static func from(_ date: Date, in zone: TimeZone) -> LocalDateTime {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return LocalDateTime(year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!)
    }

    var localDate: DateComponents { DateComponents(year: year, month: month, day: day) }

    static func < (a: LocalDateTime, b: LocalDateTime) -> Bool { a.wireString < b.wireString }
}

struct TravelStats: Sendable {
    let totalDistanceKm: Int
    let flightCount: Int
    let countryCount: Int
    let cityCount: Int
}

extension Array where Element == Flight {
    func travelStats() -> TravelStats {
        let done = filter { $0.phase == .past && !$0.isPending && $0.deletedAt == nil }
        let airports = done.flatMap { [$0.departureAirport, $0.arrivalAirport].compactMap { $0 } }
        return TravelStats(
            totalDistanceKm: done.reduce(0) { $0 + $1.distanceKm },
            flightCount: done.count,
            countryCount: Set(airports.map(\.country)).count,
            cityCount: Set(airports.map(\.city)).count
        )
    }
}

enum ThemeMode: String, CaseIterable, Codable { case system, light, dark }

/// Whether to show distances in kilometres — read from the phone's own
/// Measurement System setting (Settings ▸ General ▸ Language & Region),
/// not guessed from Region alone: a phone can have Region set to United
/// States and Measurement System set to Metric (or the other way around),
/// and going by Region alone got exactly that case backwards.
func systemPrefersMetric() -> Bool {
    Locale.current.measurementSystem == .metric
}

func formatDistance(_ km: Int) -> String {
    systemPrefersMetric() ? "\(km.formatted()) km" : "\(Int(Double(km) * 0.621371).formatted()) mi"
}

/// "T1", "Terminal 1" and "1" are the same terminal spelled three ways
/// depending on which source recorded it — decided here, once, so nowhere
/// else risks compounding an already-prefixed "T1" into a displayed "TT1".
func normalizeTerminal(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.lowercased().hasPrefix("terminal ") { s = String(s.dropFirst("terminal ".count)) }
    if s.uppercased().hasPrefix("T"), s.count > 1, s.dropFirst().first?.isNumber == true { s = String(s.dropFirst()) }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func formatDuration(_ minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
}

func greatCircleKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let r: Double = 6371.0
    let rad: Double = Double.pi / 180
    let p1: Double = lat1 * rad
    let p2: Double = lat2 * rad
    let dp: Double = (lat2 - lat1) * rad
    let dl: Double = (lon2 - lon1) * rad
    let sdp: Double = sin(dp / 2)
    let sdl: Double = sin(dl / 2)
    let a: Double = sdp * sdp + cos(p1) * cos(p2) * sdl * sdl
    let c: Double = 2 * atan2(sqrt(a), sqrt(1 - a))
    return r * c
}

/// Passenger names come as "WU/CHUNKEI", "MR CHUN KEI WU", "Chun Kei Wu". They match
/// when every token of the traveller's name is in the candidate's letters and little is left over.
enum PassengerName {
    private static let titles: Set<String> = ["MR", "MRS", "MS", "MISS", "DR", "MSTR", "MASTER"]

    static func tokens(_ name: String) -> [String] {
        name.uppercased().split { !$0.isLetter }.map(String.init).filter { !titles.contains($0) }
    }

    static func samePerson(mine: String, candidate: String) -> Bool {
        let mineTokens = tokens(mine)
        let cand = tokens(candidate).joined()
        guard !mineTokens.isEmpty, !cand.isEmpty, mineTokens.allSatisfy({ cand.contains($0) }) else { return false }
        return cand.count - mineTokens.reduce(0) { $0 + $1.count } <= 2
    }

    /// True when the ticket names people and none of them is the traveller.
    static func looksLikeSomeoneElse(_ flight: Flight, mine: String?) -> Bool {
        guard let mine, !mine.isEmpty, !flight.passengers.isEmpty else { return false }
        return !flight.passengers.contains { samePerson(mine: mine, candidate: $0) }
    }
}

/// A manually-entered ("fed") flight's automated verification outcome —
/// the server, never the client, decides which of these it ends up as: it
/// re-checks a fresh "pending" against AirLabs/AeroDataBox's own schedules,
/// adsbdb's independent route data, and whether another traveller has fed
/// the identical flight, before ever storing anything but its own verdict.
/// See backend/app/feed.py for the actual scoring.
enum FeedStatus: String, Codable, Hashable, Sendable {
    /// Still with the automated scorer (backend/app/feed.py), or with the
    /// community (backend/app/community.py) if the scorer couldn't settle
    /// it either way.
    case pending
    case approved
    /// Only ever set by an admin, never by voting alone — see community.py.
    case rejected
    /// The community's 7-day review window passed without reaching 70%
    /// approval, whatever the vote count — not the same as rejected: no
    /// one decided this was fake, it just ran out of time.
    case expired
}

/// One flight in the community's crowd-review queue or in a traveller's
/// own review history — backend/app/community.py's `ReviewOut`.
struct CommunityReview: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let flightNumber: String
    let airlineName: String
    let departure: String
    let arrival: String
    let departureTime: LocalDateTime
    let arrivalTime: LocalDateTime
    /// "pending" | "confirmed" | "rejected" | "expired" — not FeedStatus's
    /// own set of names (a review's own lifecycle, not the trip's).
    let status: String
    let approveCount: Int
    let rejectCount: Int
    let boosted: Bool
    /// Populated only where the server actually knows it: the vote just
    /// cast, or a row from /community/history/reviews.
    let myVote: Bool?

    var departureAirport: Airport? { AirportDatabase.shared.airport(departure) }
    var arrivalAirport: Airport? { AirportDatabase.shared.airport(arrival) }
}

/// A real person can't be on two flights at once — the one integrity check
/// this needs no external source for, just the traveller's own other
/// flights. An overlap is a strong sign one of the two was actually
/// imported from someone else's ticket (a shared inbox, a family member's
/// calendar invite) rather than genuinely this traveller's own.
enum FlightConflicts {
    /// Another of the traveller's own flights (never a friend's shared one,
    /// on either side) whose time in the air overlaps this one's, or nil.
    static func overlapping(_ flight: Flight, in all: [Flight]) -> Flight? {
        guard flight.sharedBy == nil, flight.status != .cancelled,
              let dep = flight.departureInstant, let arr = flight.arrivalInstant else { return nil }
        return all.first { other in
            guard other.id != flight.id, other.sharedBy == nil, other.deletedAt == nil, other.status != .cancelled,
                  let oDep = other.departureInstant, let oArr = other.arrivalInstant else { return false }
            return dep < oArr && oDep < arr
        }
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .accentColor; return }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Black or white, whichever reads on this colour.
    var onColor: Color {
        guard let c = UIColor(self).cgColor.components, c.count >= 3 else { return .white }
        let r: CGFloat = 0.2126 * c[0]
        let g: CGFloat = 0.7152 * c[1]
        let b: CGFloat = 0.0722 * c[2]
        let l: CGFloat = r + g + b
        return l > 0.45 ? Color(white: 0.07) : .white
    }
}
