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
        post(.status, at: dep.addingTimeInterval(-3 * 3600), title: "\(number) in 3 hours · \(route)",
             body: "Scheduled \(clock.string(from: dep)) · open Airadar for the latest status")
        post(.departure, at: dep.addingTimeInterval(TimeInterval(flight.delayMinutes * 60)), title: "\(number) · \(route)",
             body: flight.delayMinutes > 0 ? "Departing now, \(flight.delayMinutes) min late" : "Departing now")
        post(.landed, at: arr.addingTimeInterval(TimeInterval(flight.delayMinutes * 60) + 3600), title: "\(number) · landed",
             body: "Arrived \(flight.arrival) · usually \(formatDuration(flight.typicalDurationMinutes ?? flight.durationMinutes))")
    }

    static func cancel(_ flightId: String) {
        let ids = Stage.allCases.map { id(flightId, $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    private static func id(_ flightId: String, _ stage: Stage) -> String { "reminder:\(flightId):\(stage.rawValue)" }
}
