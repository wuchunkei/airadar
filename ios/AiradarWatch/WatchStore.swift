import Foundation
import WatchConnectivity

/// The watch app's own copy of what the phone last sent — loaded from the
/// App Group container at launch (so a relaunch shows the last-known state
/// at once, phone or no phone nearby), updated live whenever WatchConnectivity
/// delivers a fresher one.
@MainActor
final class WatchStore: NSObject, ObservableObject {
    static let shared = WatchStore()

    @Published private(set) var snapshot: WatchSnapshot = WatchSnapshotStore.load()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func apply(_ data: Data) {
        guard let decoded = try? JSONDecoder.watch.decode(WatchSnapshot.self, from: data) else { return }
        snapshot = decoded
        WatchSnapshotStore.save(decoded)
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["snapshot"] as? Data else { return }
        Task { @MainActor in WatchStore.shared.apply(data) }
    }

    #if os(iOS)
    // Not part of watchOS's own WCSessionDelegate (only one watch is ever
    // paired to it, so there's no "another session took over" to report;
    // watchOS's protocol marks both unavailable) -- present anyway because
    // a watch target still gets a pass compiled against the iOS SDK for
    // tooling, where these two are required.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
