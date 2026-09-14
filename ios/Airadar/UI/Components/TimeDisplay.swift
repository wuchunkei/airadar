import Foundation

/// A time as shown on a card: the clock and the zone tag beside it —
/// `08:05 GMT+8` in the airport's own zone, or `HKT(+1)` style when the traveller
/// asked for everything in the phone's zone and the day shifted.
struct ShownTime: Hashable {
    let clock: String
    let zone: String
    /// The original clock when a delay moved it, for the strikethrough.
    let original: String?
}

extension Flight {
    func shownTime(arrival: Bool, forceSystemZone: Bool, includeDelay: Bool = true) -> ShownTime {
        let local = arrival ? arrivalTime : departureTime
        let airport = arrival ? arrivalAirport : departureAirport
        let zone = airport?.zone ?? .gmt
        let shifted = (includeDelay && delayMinutes > 0)
            ? LocalDateTime.from(local.date(in: zone).addingTimeInterval(TimeInterval(delayMinutes * 60)), in: zone)
            : local
        if forceSystemZone {
            let instant = shifted.date(in: zone)
            let mine = LocalDateTime.from(instant, in: .current)
            let dayShift = daysBetween(shifted.dayString, mine.dayString)
            let tag = TimeZone.current.abbreviation() ?? "local"
            let suffix = dayShift == 0 ? "" : (dayShift > 0 ? "(+\(dayShift))" : "(\(dayShift))")
            return ShownTime(clock: mine.clock, zone: tag + suffix, original: delayMinutes > 0 && includeDelay ? LocalDateTime.from(local.date(in: zone), in: .current).clock : nil)
        }
        return ShownTime(clock: shifted.clock, zone: gmtTag(zone), original: delayMinutes > 0 && includeDelay ? local.clock : nil)
    }

    private func gmtTag(_ zone: TimeZone) -> String {
        let hours = zone.secondsFromGMT() / 3600
        let mins = abs(zone.secondsFromGMT() % 3600) / 60
        return "GMT" + (hours >= 0 ? "+" : "") + "\(hours)" + (mins > 0 ? ":\(String(format: "%02d", mins))" : "")
    }

    private func daysBetween(_ a: String, _ b: String) -> Int {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .gmt
        guard let da = f.date(from: a), let db = f.date(from: b) else { return 0 }
        return Int((db.timeIntervalSince(da) / 86400).rounded())
    }
}
