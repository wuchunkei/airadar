import ActivityKit
import Foundation

/// Starts, refreshes and ends the Live Activity for flights of the day: from eight
/// hours before departure until half an hour after landing, one per flight.
@MainActor
enum LiveActivities {
    private static let leadIn: TimeInterval = 8 * 3600
    private static let linger: TimeInterval = 30 * 60

    static func sync(_ flights: [Flight]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now = Date()
        let wanted = flights.filter { f in
            guard f.deletedAt == nil, let dep = f.departureInstant, let arr = f.arrivalInstant else { return false }
            let delay = TimeInterval(f.delayMinutes * 60)
            return dep + delay - leadIn <= now && now <= arr + delay + linger && f.status != .cancelled
        }
        let running = Activity<FlightActivityAttributes>.activities
        for a in running where !wanted.contains(where: { $0.id == a.attributes.tripId }) {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        for f in wanted {
            let content = ActivityContent(state: contentState(f), staleDate: now.addingTimeInterval(30 * 60))
            if let a = running.first(where: { $0.attributes.tripId == f.id }) {
                Task { await a.update(content) }
            } else {
                _ = try? Activity.request(attributes: attributes(f), content: content)
            }
        }
    }

    private static func attributes(_ f: Flight) -> FlightActivityAttributes {
        FlightActivityAttributes(
            tripId: f.id, flightNumber: f.flightNumber, airlineName: f.airlineName,
            departure: f.departure, arrival: f.arrival,
            departureCity: f.departureAirport?.city ?? f.departure, arrivalCity: f.arrivalAirport?.city ?? f.arrival,
            departureTerminal: f.departureTerminal, arrivalTerminal: f.arrivalTerminal)
    }

    private static func contentState(_ f: Flight) -> FlightActivityAttributes.ContentState {
        let delay = TimeInterval(f.delayMinutes * 60)
        let dep = f.shownTime(arrival: false, forceSystemZone: false)
        let arr = f.shownTime(arrival: true, forceSystemZone: false)
        return .init(
            statusLabel: f.status.label, statusKind: kind(f.status),
            departureDate: (f.departureInstant ?? Date()) + delay, arrivalDate: (f.arrivalInstant ?? Date()) + delay,
            departureClock: dep.clock, arrivalClock: arr.clock,
            departureGate: f.departureGate, arrivalGate: f.arrivalGate, baggageClaim: f.baggageClaim,
            delayMinutes: f.delayMinutes)
    }

    private static func kind(_ s: FlightStatus) -> FlightActivityAttributes.StatusKind {
        switch s {
        case .scheduled: .scheduled
        case .boarding, .departed, .inFlight: .live
        case .onTime, .landed, .completed: .good
        case .delayed: .warn
        case .cancelled, .diverted: .bad
        }
    }
}
