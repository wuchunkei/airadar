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
        BackgroundRefresh.register()
        WatchSync.shared.activate()
        #if DEBUG
        NetworkProbe.runIfAsked()
        #endif
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
                // Leaving it: queue the best-effort background wake, since
                // nothing else will keep the Live Activity fresh once this
                // loop below stops running.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, auth.isSignedIn { Task { try? await store.syncFromServer() } }
                    if phase == .background { BackgroundRefresh.schedule() }
                }
                // While a flight is near: the Live Activity rewritten every minute (its colours
                // are the app's to write; the countdown and progress bar tick by themselves);
                // the server asked every minute around the flight itself, every second one otherwise.
                .task {
                    var minute = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        minute += 1
                        guard store.hasFlightNearNow else { continue }
                        if store.hasFlightInLiveWindow || minute % 2 == 0, auth.isSignedIn { try? await store.syncFromServer() }
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

#if DEBUG
/// Development aid: launched with `-probe <url> [<url> …]`, fetches each URL
/// from wherever the phone is and saves the answer under Library/Caches/probe/
/// (status line, headers, body) — for studying sites that only answer visitors
/// inside mainland China, which a Mac abroad can't reach.
enum NetworkProbe {
    static func runIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-probe") else { return }
        let urls = args[(i + 1)...].prefix { !$0.hasPrefix("-") }.compactMap(URL.init(string:))
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("probe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task.detached {
            for (n, url) in urls.enumerated() {
                var req = URLRequest(url: url, timeoutInterval: 25)
                req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                req.setValue("https://\(url.host ?? "")/", forHTTPHeaderField: "Referer")
                var text = "URL \(url.absoluteString)\n"
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse {
                        text += "STATUS \(http.statusCode)\n"
                        for (k, v) in http.allHeaderFields { text += "\(k): \(v)\n" }
                    }
                    text += "\n" + (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
                } catch {
                    text += "ERROR \(error)\n"
                }
                try? text.write(to: dir.appendingPathComponent("\(n).txt"), atomically: true, encoding: .utf8)
            }
            try? "done".write(to: dir.appendingPathComponent("done"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
