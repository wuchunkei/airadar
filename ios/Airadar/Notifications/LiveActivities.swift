import ActivityKit
import Foundation

/// Starts, refreshes and ends the Live Activity for flights of the day: from a few
/// hours before departure until half an hour after landing, one per flight.
@MainActor
enum LiveActivities {
    nonisolated private static let linger: TimeInterval = 30 * 60

    /// How long before departure the activity starts. iOS ends an activity eight
    /// hours after it starts, so the lead-in shrinks for longer flights to keep
    /// the flight itself and the landing inside that window: three hours for a
    /// short hop, down to half an hour for a long-haul that can't fit anyway.
    nonisolated static func leadIn(for f: Flight) -> TimeInterval {
        guard let dep = f.departureInstant, let arr = f.arrivalInstant else { return 3 * 3600 }
        let room = 8 * 3600 - 10 * 60 - max(0, arr.timeIntervalSince(dep)) - linger
        return min(3 * 3600, max(30 * 60, room))
    }

    static func sync(_ flights: [Flight]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now = Date()
        let wanted = flights.filter { f in
            guard f.deletedAt == nil, let dep = f.departureInstant, let arr = f.expectedArrival else { return false }
            let delay = TimeInterval(f.delayMinutes * 60)
            return dep + delay - leadIn(for: f) <= now && now <= arr + linger && f.status != .cancelled
        }
        let running = Activity<FlightActivityAttributes>.activities
        for a in running where !wanted.contains(where: { $0.id == a.attributes.tripId }) {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        for f in wanted {
            let content = ActivityContent(state: contentState(f), staleDate: nextStageChange(f, after: now))
            if let a = running.first(where: { $0.attributes.tripId == f.id }) {
                // Attributes cannot change; one started before its mark arrived is replaced.
                if a.attributes.logo == nil, let logo = AirlineLogos.thumbnail(for: f.flightNumber, onArrival: {}) {
                    Task {
                        await a.end(nil, dismissalPolicy: .immediate)
                        _ = try? Activity.request(attributes: attributes(f, logo: logo), content: content)
                    }
                } else {
                    Task { await a.update(content) }
                }
            } else {
                // Attributes are fixed for the activity's life, so the logo has to be there at the start.
                let logo = AirlineLogos.thumbnail(for: f.flightNumber) {
                    Task { @MainActor in sync(FlightStore.shared.flights) }
                }
                _ = try? Activity.request(attributes: attributes(f, logo: logo), content: content)
            }
        }
    }

    /// When the widget next has to be redrawn with nothing new from the app: the
    /// moment it takes off, then the moment it lands. The system redraws a Live
    /// Activity once it goes stale, which is what flips the island from counting
    /// down to boarding to counting down to landing while the app is asleep.
    private static func nextStageChange(_ f: Flight, after now: Date) -> Date {
        let delay = TimeInterval(f.delayMinutes * 60)
        let edges = [f.departureInstant.map { $0 + delay }, f.expectedArrival].compactMap { $0 }
        return edges.first { $0 > now } ?? now.addingTimeInterval(16 * 60)
    }

    private static func waypoints(_ f: Flight) -> [FlightActivityAttributes.Waypoint] {
        guard let a = f.departureAirport, let b = f.arrivalAirport else { return [] }
        return RouteAirports.along(from: a, to: b).map { .init(fraction: $0.fraction, code: $0.code) }
    }

    private static func attributes(_ f: Flight, logo: Data?) -> FlightActivityAttributes {
        FlightActivityAttributes(
            tripId: f.id, flightNumber: f.flightNumber, airlineName: f.airlineName,
            departure: f.departure, arrival: f.arrival,
            departureCity: f.departureAirport?.cityCountry ?? f.departure, arrivalCity: f.arrivalAirport?.cityCountry ?? f.arrival,
            departureTerminal: f.departureTerminal, arrivalTerminal: f.arrivalTerminal,
            distanceKm: distanceKm(f), logo: logo)
    }

    /// Great-circle distance between the two airports, whole kilometres.
    private static func distanceKm(_ f: Flight) -> Int {
        guard let a = f.departureAirport, let b = f.arrivalAirport else { return 0 }
        let rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return Int((2 * 6371 * asin(sqrt(h))).rounded())
    }

    private static func contentState(_ f: Flight) -> FlightActivityAttributes.ContentState {
        let delay = TimeInterval(f.delayMinutes * 60)
        let dep = f.shownTime(arrival: false, forceSystemZone: false)
        let arr = f.shownTime(arrival: true, forceSystemZone: false)
        return .init(
            // Before it leaves, where boarding has got to reads better than "Scheduled".
            statusLabel: f.currentBoarding?.label ?? f.status.label, statusKind: f.currentBoarding.map(kind) ?? kind(f.status),
            departureDate: (f.departureInstant ?? Date()) + delay, arrivalDate: f.expectedArrival ?? Date(),
            departureClock: dep.clock, arrivalClock: arr.clock,
            departureGate: f.departureGate, arrivalGate: f.arrivalGate, baggageClaim: f.baggageClaim,
            delayMinutes: f.delayMinutes, landed: f.status == .landed || f.status == .completed,
            arrivalDelayMinutes: f.arrivalDelayMinutes,
            waypoints: waypoints(f))
    }

    private static func kind(_ b: BoardingStatus) -> FlightActivityAttributes.StatusKind {
        switch b {
        case .checkIn: .scheduled
        case .gateOpen, .boarding: .live
        case .finalCall, .gateClosing: .warn
        case .gateClosed: .bad
        }
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
