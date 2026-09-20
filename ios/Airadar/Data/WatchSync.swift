import Foundation
import WatchConnectivity

/// Keeps the watch app's own view of things current: whenever FlightStore's
/// list changes, a fresh WatchSnapshot goes out over WatchConnectivity and
/// into the shared App Group container the watch's widget extension reads
/// from too. No sign-in and no networking of its own on the watch side in
/// this first pass -- it just mirrors what the phone already knows,
/// `updateApplicationContext` being the right tool for "here's the latest
/// state" (it replaces whatever the watch hasn't picked up yet rather than
/// queuing every call, and delivers next time the watch is reachable even
/// if that's a while from now).
@MainActor
final class WatchSync: NSObject {
    static let shared = WatchSync()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Only what a wrist actually wants: the next several trips, oldest
    /// first, each date already an absolute instant -- the watch has no
    /// airport-timezone database to resolve a bare local clock reading
    /// against, so that work happens here, once, while the phone already
    /// has everything it needs to do it.
    func sync(_ flights: [Flight]) {
        let trips: [WatchTrip] = flights
            .filter { $0.deletedAt == nil && $0.status != .cancelled }
            .compactMap { f in
                guard let dep = f.departureInstant, let arr = f.arrivalInstant else { return nil }
                let delay = TimeInterval(f.delayMinutes * 60)
                return WatchTrip(
                    id: f.id, flightNumber: f.flightNumber, airlineName: f.airlineName,
                    departure: f.departure, arrival: f.arrival,
                    departureCity: f.departureAirport?.cityCountry ?? f.departure,
                    arrivalCity: f.arrivalAirport?.cityCountry ?? f.arrival,
                    departureTerminal: f.departureTerminal, departureGate: f.departureGate, arrivalGate: f.arrivalGate,
                    departureDate: dep + delay, arrivalDate: arr + delay,
                    statusLabel: f.displayStatus.label, statusKind: Self.kind(f.displayStatus), delayMinutes: f.delayMinutes)
            }
            .sorted { $0.departureDate < $1.departureDate }
            .prefix(10)
            .map { $0 }

        // WatchSnapshotStore's App Group container is local to whichever
        // device writes it -- the phone and watch each have their own, so
        // there's nothing to save here on the phone's side; the watch app
        // is what writes its copy, once this reaches it over WCSession.
        let snapshot = WatchSnapshot(trips: trips, generatedAt: Date())

        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? JSONEncoder.watch.encode(snapshot) else { return }
        try? WCSession.default.updateApplicationContext(["snapshot": data])
    }

    private static func kind(_ s: FlightStatus) -> WatchStatusKind {
        switch s {
        case .scheduled: .scheduled
        case .boarding, .departed, .inFlight: .live
        case .onTime, .landed, .completed: .good
        case .delayed: .warn
        case .cancelled, .diverted: .bad
        }
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated { Task { @MainActor in WatchSync.shared.sync(FlightStore.shared.flights) } }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
