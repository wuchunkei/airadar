import SwiftUI
import GoogleSignIn

@main
struct AiradarApp: App {
    @StateObject private var store = FlightStore.shared
    @StateObject private var auth = AuthStore.shared
    @StateObject private var settings = SettingsModel.shared

    @Environment(\.scenePhase) private var scenePhase

    init() {
        GoogleAuth.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(auth)
                .environmentObject(settings)
                .preferredColorScheme(settings.themeMode.colorScheme)
                .onOpenURL { url in
                    // airadar://s/<token> and https://<host>/s/<token>: a trip someone shared.
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    let isLink = (url.scheme == "airadar" && url.host == "s") ||
                        (url.scheme == "https" && url.pathComponents.dropFirst().first == "s")
                    if isLink, let token = url.pathComponents.last, token != "s" { DeepLinks.shared.shareToken = token }
                }
                .task {
                    await FlightReminders.requestPermission()
                    if auth.isSignedIn {
                        _ = try? await BackendClient.me()
                        try? await store.syncFromServer()
                    }
                }
                // Back to the foreground: the day's flights may have moved.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, auth.isSignedIn { Task { try? await store.syncFromServer() } }
                }
                // While a flight is near: the Live Activity rewritten every minute (its countdown,
                // colours and the plane's place are the app's to write); the server asked every second minute.
                .task {
                    var minute = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        minute += 1
                        guard store.hasFlightNearNow else { continue }
                        if minute % 2 == 0, auth.isSignedIn { try? await store.syncFromServer() }
                        else { LiveActivities.sync(store.flights) }
                    }
                }
        }
    }
}

/// A trip link opened from outside; the root view shows it.
@MainActor
final class DeepLinks: ObservableObject {
    static let shared = DeepLinks()
    @Published var shareToken: String?
}

/// Preferences that live on the phone: appearance, zone display, calendar switch.
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    private let defaults = UserDefaults.standard

    @Published var themeMode: ThemeMode { didSet { defaults.set(themeMode.rawValue, forKey: "themeMode") } }
    @Published var forceSystemZone: Bool { didSet { defaults.set(forceSystemZone, forKey: "forceSystemZone") } }
    @Published var calendarSync: Bool { didSet { defaults.set(calendarSync, forKey: "calendarSync") } }
    /// Calendar identifiers to read; empty means none chosen yet.
    @Published var calendarIds: [String] { didSet { defaults.set(calendarIds, forKey: "calendarIds") } }

    private init() {
        themeMode = ThemeMode(rawValue: defaults.string(forKey: "themeMode") ?? "") ?? .system
        forceSystemZone = defaults.bool(forKey: "forceSystemZone")
        calendarSync = defaults.bool(forKey: "calendarSync")
        calendarIds = defaults.stringArray(forKey: "calendarIds") ?? []
    }
}

extension ThemeMode {
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}
