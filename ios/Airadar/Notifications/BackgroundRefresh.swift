import BackgroundTasks
import Foundation

/// Best-effort background refresh for the Live Activity while the app isn't
/// open. Pushing an update in from the server the moment something changes
/// needs the Push Notifications entitlement plus an APNs auth key — both
/// gated behind a paid Apple Developer Program membership, which this app
/// doesn't have (same wall as the Wallet card). This is the free-tier
/// fallback instead: ask iOS to wake the app briefly on its own schedule,
/// and use that moment to rewrite the Live Activity from whatever's cached
/// and, if there's a moment left, pull a fresh status too. iOS decides
/// whether and when it actually runs — there is no guaranteed interval, and
/// under Low Power Mode or heavy battery pressure it may not run at all.
@MainActor
enum BackgroundRefresh {
    static let taskId = "com.airadar.app.refresh"

    /// Called once at launch, before the first `schedule()`.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            // BGTaskScheduler's own handler runs off the main actor; hop back
            // on for FlightStore/LiveActivities, both of which live there.
            Task { @MainActor in handle(task as! BGAppRefreshTask) }
        }
    }

    /// Call whenever the app leaves the foreground, so there's always one
    /// more refresh queued behind it — each request is one-shot.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        // A floor, not a promise: the system is free to run it later than this.
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule() // queue the next one before this one's ~30s budget runs out
        let work = Task { @MainActor in
            guard FlightStore.shared.hasFlightNearNow else { task.setTaskCompleted(success: true); return }
            if AuthStore.shared.isSignedIn { try? await FlightStore.shared.syncFromServer() }
            LiveActivities.sync(FlightStore.shared.flights)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
