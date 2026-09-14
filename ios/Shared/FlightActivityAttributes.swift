import ActivityKit
import Foundation

/// What the Live Activity / Dynamic Island shows for one flight. Compiled into
/// both the app (which starts and updates it) and the widget extension (which draws it).
struct FlightActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusLabel: String
        var statusKind: StatusKind
        /// Instants, delay included, so the island can count down and draw progress.
        var departureDate: Date
        var arrivalDate: Date
        /// Local clocks at each airport, as printed on the card.
        var departureClock: String
        var arrivalClock: String
        var departureGate: String?
        var arrivalGate: String?
        var baggageClaim: String?
        var delayMinutes: Int
    }

    enum StatusKind: String, Codable, Hashable { case scheduled, live, good, warn, bad }

    let tripId: String
    let flightNumber: String
    let airlineName: String
    let departure: String
    let arrival: String
    let departureCity: String
    let arrivalCity: String
    let departureTerminal: String?
    let arrivalTerminal: String?
    /// A tiny JPEG of the airline's mark, when one could be had.
    let logo: Data?
}
