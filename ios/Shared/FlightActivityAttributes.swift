import CoreGraphics
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
        /// Local clocks at each airport, as printed on the card (delay included).
        var departureClock: String
        var arrivalClock: String
        var departureGate: String?
        var arrivalGate: String?
        var baggageClaim: String?
        var delayMinutes: Int
        /// Set once the airline reports the flight down; the arrival clock is then the landing time.
        var landed: Bool = false
        /// How far the arrival moved from the timetable (negative early), once the
        /// source says; for "Landed · 11m early" rather than the departure's delay.
        var arrivalDelayMinutes: Int? = nil
        /// Cities along the way, as airport (or city) codes: dots on the route
        /// line, the next one named beneath it in the air — picked by the clock
        /// whenever the widget draws, so it moves on without an update from the app.
        var waypoints: [Waypoint] = []
    }

    struct Waypoint: Codable, Hashable {
        /// How far along the route, 0 at departure, 1 at arrival.
        var fraction: Double
        /// The airport or city code, or the city's name in the app's language
        /// when it has one (深圳 rather than SZX) — whatever the line shows.
        var code: String
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
    /// Great-circle distance between the two airports.
    let distanceKm: Int
    /// A tiny JPEG of the airline's mark, when one could be had.
    let logo: Data?
}

/// Which of the labels along a route line fit side by side, left to right: each
/// needs its own width clear of the last one kept, so short codes pack closer
/// than longer city names.
enum WaypointLabels {
    static func fitting(_ items: [(fraction: Double, label: String)], span: CGFloat) -> Set<Int> {
        var kept: Set<Int> = []
        var lastX = -CGFloat.infinity, lastHalf: CGFloat = 0
        for (i, item) in items.enumerated() {
            let x = span * item.fraction, half = width(of: item.label) / 2
            if x - lastX >= lastHalf + half + 4 { kept.insert(i); lastX = x; lastHalf = half }
        }
        return kept
    }

    /// Roughly how wide a 9pt label draws: CJK characters full width, the rest monospaced.
    static func width(of label: String) -> CGFloat {
        label.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 9.5 : 5.6) }
    }
}
