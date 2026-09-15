import Foundation

/// Build-time settings, pulled from Config.xcconfig through Info.plist.
enum Config {
    private static func plist(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    static var backendURL: String { plist("BACKEND_URL").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    static var backendToken: String { plist("BACKEND_TOKEN") }
    static var openSkyClientId: String { plist("OPENSKY_CLIENT_ID") }
    static var openSkyClientSecret: String { plist("OPENSKY_CLIENT_SECRET") }
    static var linkHost: String { plist("LINK_HOST") }
    static var googleClientId: String { plist("GIDClientID") }
    static var googleServerClientId: String { plist("GIDServerClientID") }
    static var aeroDataBoxKey: String { plist("AERODATABOX_KEY") }

    static var isBackendConfigured: Bool { !backendURL.isEmpty }
    static var isOpenSkyConfigured: Bool { !openSkyClientId.isEmpty && !openSkyClientSecret.isEmpty }
    static var isAeroDataBoxConfigured: Bool { !aeroDataBoxKey.isEmpty }
}
