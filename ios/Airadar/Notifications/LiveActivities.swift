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
            let content = ActivityContent(state: contentState(f), staleDate: now.addingTimeInterval(3 * 60))
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
            statusLabel: f.status.label, statusKind: kind(f.status),
            departureDate: (f.departureInstant ?? Date()) + delay, arrivalDate: (f.arrivalInstant ?? Date()) + delay,
            departureClock: dep.clock, arrivalClock: arr.clock,
            departureGate: f.departureGate, arrivalGate: f.arrivalGate, baggageClaim: f.baggageClaim,
            delayMinutes: f.delayMinutes, landed: f.status == .landed || f.status == .completed,
            countdown: countdown(f, delay: delay))
    }

    /// "1h04m" above an hour, "4m50s" inside it; to departure before, to landing in the air.
    static func countdown(_ f: Flight, delay: TimeInterval) -> String {
        let now = Date()
        guard let dep = f.departureInstant, let arr = f.arrivalInstant else { return "" }
        let target = now < dep + delay ? dep + delay : arr + delay
        let left = max(0, Int(target.timeIntervalSince(now)))
        if left >= 3600 { return String(format: "%dh%02dm", left / 3600, (left % 3600) / 60) }
        return String(format: "%dm%02ds", left / 60, left % 60)
    }

    /// Something to count down within the hour: the activity is then rewritten every half minute.
    static func inLastHour(_ flights: [Flight]) -> Bool {
        let now = Date()
        return flights.contains { f in
            guard let dep = f.departureInstant, let arr = f.arrivalInstant else { return false }
            let delay = TimeInterval(f.delayMinutes * 60)
            let target = now < dep + delay ? dep + delay : arr + delay
            let left = target.timeIntervalSince(now)
            return left > 0 && left < 3600
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
