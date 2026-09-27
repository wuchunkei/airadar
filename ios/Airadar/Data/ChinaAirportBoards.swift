import Foundation

/// Boarding progress, gate, delay, actual times and belt from the flight
/// boards of mainland Chinese airports — read by the phone itself, since these
/// sites only answer visitors inside mainland China (the backend, abroad, is
/// turned away). Anyone flying from or to one of these airports is usually in
/// the mainland around then; anywhere else the request just fails, quietly.
///
/// Shenzhen Bao'an: the JSON behind its own departures/arrivals pages
/// (szairport.com, /szjchbjk/hbcx/flightInfo), as its airlineNew.js reads it.
enum ChinaAirportBoards {
    static let airports: Set<String> = ["SZX"]

    private static let zone = TimeZone(identifier: "Asia/Shanghai")!
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        return URLSession(configuration: c)
    }()

    /// Worth asking about: departing within the next three hours or so, or
    /// arriving within a few hours either side of now.
    static func applies(to f: Flight, now: Date = Date()) -> Bool {
        guard !f.isManual, f.deletedAt == nil else { return false }
        if airports.contains(f.departure), let dep = f.departureInstant,
           now > dep.addingTimeInterval(-3 * 3600), now < dep.addingTimeInterval(TimeInterval(f.delayMinutes * 60) + 2 * 3600) { return true }
        if airports.contains(f.arrival), let dep = f.departureInstant, let arr = f.arrivalInstant,
           now > dep, now < arr.addingTimeInterval(3 * 3600) { return true }
        return false
    }

    /// The flight with whatever the boards say applied; nil when they said
    /// nothing new (or couldn't be reached).
    static func update(_ flight: Flight, now: Date = Date()) async -> Flight? {
        var f = flight
        if airports.contains(f.departure), let row = await szxRow(f, flag: "D", now: now) { applyDeparture(row, to: &f) }
        if airports.contains(f.arrival), let row = await szxRow(f, flag: "A", now: now) { applyArrival(row, to: &f) }
        return f == flight ? nil : f
    }

    // MARK: - Shenzhen

    private static func szxRow(_ f: Flight, flag: String, now: Date) async -> [String: Any]? {
        // The board keys a day as yesterday/today/tomorrow (0/1/2) on its own clock;
        // time block 12 is the whole day.
        let day = flag == "D" ? f.departureTime : f.arrivalTime
        let today = LocalDateTime.from(now, in: zone)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        guard let a = cal.date(from: today.localDate), let b = cal.date(from: day.localDate),
              let diff = cal.dateComponents([.day], from: a, to: b).day, (-1...1).contains(diff) else { return nil }
        var parts = URLComponents(string: "https://www.szairport.com/szjchbjk/hbcx/flightInfo")!
        parts.queryItems = [.init(name: "type", value: "cn"), .init(name: "flag", value: flag),
                            .init(name: "currentDate", value: String(diff + 1)), .init(name: "currentTime", value: "12"),
                            .init(name: "hbxx_hbh", value: f.flightNumber)]
        guard let url = parts.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("https://www.szairport.com/", forHTTPHeaderField: "Referer")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["flightList"] as? [[String: Any]] else { return nil }
        let wanted = normalize(f.flightNumber)
        return list.first { row in
            let numbers = (row["hbh"] as? [[String: Any]])?.compactMap { $0["flightNo"] as? String } ?? []
            return numbers.contains { normalize($0) == wanted }
        }
    }

    /// Status codes, "#"-separated, as the board accumulates them through the day.
    private static func codes(_ row: [String: Any]) -> Set<String> {
        Set(string(row["fltNormalStatus2"]).split(separator: "#").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
    }

    private static func applyDeparture(_ row: [String: Any], to f: inout Flight) {
        let c = codes(row)
        if let gate = nonEmpty(row["gateCode"]), gate != f.departureGate {
            if let old = f.departureGate { f.departureGatePrevious = old }
            f.departureGate = gate
        }
        // The furthest boarding stage reached: 开始值机, 开始登机, 催促登机, 结束登机.
        if c.contains("POK") { f.boardingStatus = .gateClosed }
        else if c.contains("LBD") { f.boardingStatus = .finalCall }
        else if c.contains("BOR") || c.contains("TBR") { f.boardingStatus = .boarding }
        else if c.contains("CKI") { f.boardingStatus = .checkIn }

        let scheduled = f.departureTime
        if let moved = time(row["startRealTakeoffTime"], near: scheduled) {
            f.delayMinutes = max(0, minutes(from: scheduled, to: moved))
        }
        // Never backwards: a flight already known to be in the air or down
        // stays so, whatever the departure board last said about it.
        guard ![.inFlight, .landed, .completed, .cancelled, .diverted].contains(f.status) else { return }
        if c.contains("CAN") { f.status = .cancelled }
        else if c.contains("ALT") { f.status = .diverted }
        else if c.contains("DEP") { f.status = .departed }
        else if c.contains("DLY") || f.delayMinutes > 0 { f.status = .delayed }
    }

    private static func applyArrival(_ row: [String: Any], to f: inout Flight) {
        let c = codes(row)
        let scheduled = f.arrivalTime
        if let moved = time(row["terminalRealLandinTime"], near: scheduled) {
            f.arrivalDelayMinutes = minutes(from: scheduled, to: moved)
        }
        if c.contains("ARR") || c.contains("NST") { f.status = .landed }
        else if c.contains("CAN") { f.status = .cancelled }
        else if c.contains("ALT") { f.status = .diverted }
        if let belt = nonEmpty(row["blls"]), belt != f.baggageClaim {
            if let old = f.baggageClaim { f.baggageClaimPrevious = old }
            f.baggageClaim = belt
        }
    }

    // MARK: - Parsing

    private static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: ""
        }
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        let s = string(v).trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s == "-" || s == "--" ? nil : s
    }

    /// "21:35", "2026-09-27 21:35", "2026-09-27 21:35:00" or "202609272135",
    /// on the day nearest the scheduled time when only a clock is given.
    private static func time(_ v: Any?, near scheduled: LocalDateTime) -> LocalDateTime? {
        let s = string(v).trimmingCharacters(in: .whitespaces)
        if s.count >= 16, let full = LocalDateTime(string: s.replacingOccurrences(of: " ", with: "T")) { return full }
        if s.count == 12, s.allSatisfy(\.isNumber),
           let y = Int(s.prefix(4)), let mo = Int(s.dropFirst(4).prefix(2)), let d = Int(s.dropFirst(6).prefix(2)),
           let h = Int(s.dropFirst(8).prefix(2)), let mi = Int(s.suffix(2)) {
            return LocalDateTime(year: y, month: mo, day: d, hour: h, minute: mi)
        }
        let clock = s.split(separator: ":")
        guard clock.count >= 2, let h = Int(clock[0]), let mi = Int(clock[1].prefix(2)), (0..<24).contains(h) else { return nil }
        let base = scheduled.date(in: zone)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let sameDay = cal.date(bySettingHour: h, minute: mi, second: 0, of: base) ?? base
        let nearest = [-1, 0, 1].compactMap { cal.date(byAdding: .day, value: $0, to: sameDay) }
            .min { abs($0.timeIntervalSince(base)) < abs($1.timeIntervalSince(base)) } ?? sameDay
        return LocalDateTime.from(nearest, in: zone)
    }

    private static func minutes(from a: LocalDateTime, to b: LocalDateTime) -> Int {
        Int((b.date(in: zone).timeIntervalSince(a.date(in: zone)) / 60).rounded())
    }

    /// "HU 7744", "hu07744" → "HU7744".
    private static func normalize(_ number: String) -> String {
        let s = number.uppercased().filter { !$0.isWhitespace }
        let prefix = String(s.prefix(2)), rest = s.dropFirst(2)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits) else { return s }
        return prefix + String(n) + rest.dropFirst(digits.count)
    }
}
