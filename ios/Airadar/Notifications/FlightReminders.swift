import Foundation
import UserNotifications

/// The reminder ladder for a trip, as local notifications:
///   T-16h  "tomorrow"        T-3h   status       T-0    departure / delay
///   in flight  progress (refreshed by the app while it runs)    T+1h after landing  result
/// Live Activities / Dynamic Island for the in-flight stage come with the widget extension (phase 2).
enum FlightReminders {

    enum Stage: String, CaseIterable { case scheduled, status, departure, landed }

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func schedule(_ flight: Flight) {
        guard let dep = flight.departureInstant, let arr = flight.arrivalInstant else { return }
        cancel(flight.id)
        let route = "\(flight.departure) → \(flight.arrival)"
        let who = flight.sharedBy.map { "\($0.person.givenName)'s trip · " } ?? ""
        let number = who + flight.flightNumber
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        clock.timeZone = flight.departureAirport?.zone ?? .current

        func post(_ stage: Stage, at date: Date, title: String, body: String) {
            guard date > Date() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = flight.id
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow, repeats: false)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id(flight.id, stage), content: content, trigger: trigger))
        }

        let terminal = flight.departureTerminal.map { " from Terminal \($0)" } ?? ""
        post(.scheduled, at: dep.addingTimeInterval(-16 * 3600), title: "\(number) tomorrow · \(route)",
             body: "Departs \(clock.string(from: dep))\(terminal)")
        // Timed to when its Live Activity can start: iOS only lets the app start
        // one while it's open, so this is the nudge to open it.
        post(.status, at: dep.addingTimeInterval(-LiveActivities.leadIn(for: flight)), title: "\(number) · \(route)",
             body: "Departs \(clock.string(from: dep)) · open Airadar to follow it live on your Lock Screen")
        post(.departure, at: dep.addingTimeInterval(TimeInterval(flight.delayMinutes * 60)), title: "\(number) · \(route)",
             body: flight.delayMinutes > 0 ? "Departing now, \(flight.delayMinutes) min late" : "Departing now")
        post(.landed, at: arr.addingTimeInterval(TimeInterval(flight.delayMinutes * 60) + 3600), title: "\(number) · landed",
             body: "Arrived \(flight.arrival) · usually \(formatDuration(flight.typicalDurationMinutes ?? flight.durationMinutes))")
    }

    /// A flight of the day whose delay, status or gate changed since the last sync: say so now.
    static func announceChange(from old: Flight, to new: Flight) {
        guard let dep = new.departureInstant, abs(dep.timeIntervalSinceNow) < 36 * 3600 else { return }
        var lines: [String] = []
        if new.delayMinutes != old.delayMinutes {
            let t = new.shownTime(arrival: false, forceSystemZone: false)
            lines.append(new.delayMinutes > 0 ? "Delayed \(new.delayMinutes) min — now departing \(t.clock)" : "Back on time — departing \(t.clock)")
        }
        if new.status != old.status, new.delayMinutes == old.delayMinutes { lines.append(new.status.label) }
        // Boarding stages worth knowing the moment they happen, with the gate beside them.
        if new.boardingStatus != old.boardingStatus, let b = new.currentBoarding, b.announced {
            lines.append(new.departureGate.map { "\(b.label) · Gate \($0)" } ?? b.label)
        } else if new.departureGate != old.departureGate, let g = new.departureGate {
            lines.append("Gate \(g)")
        }
        if new.baggageClaim != old.baggageClaim, let b = new.baggageClaim { lines.append("Baggage belt \(b)") }
        guard !lines.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(new.flightNumber) \(new.departure) → \(new.arrival)"
        content.body = lines.joined(separator: " · ")
        content.sound = .default
        content.threadIdentifier = new.id
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "change:\(new.id):\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    static func cancel(_ flightId: String) {
        let ids = Stage.allCases.map { id(flightId, $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    private static func id(_ flightId: String, _ stage: Stage) -> String { "reminder:\(flightId):\(stage.rawValue)" }
}
