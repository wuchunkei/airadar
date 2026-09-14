import Foundation

/// Twenty airports bundled so the map draws before the network answers; anything
/// else is fetched from the server once and remembered for the session.
final class AirportDatabase: @unchecked Sendable {
    static let shared = AirportDatabase()

    private let lock = NSLock()
    private var learned: [String: Airport] = [:]

    private let bundled: [String: Airport] = {
        let rows: [(String, String, String, String, String, String, Double, Double, String)] = [
            ("SZX", "ZGSZ", "Shenzhen Bao'an", "Shenzhen", "China", "CN", 22.639, 113.811, "Asia/Shanghai"),
            ("ICN", "RKSI", "Incheon", "Seoul", "South Korea", "KR", 37.469, 126.451, "Asia/Seoul"),
            ("HKG", "VHHH", "Hong Kong", "Hong Kong", "Hong Kong", "HK", 22.308, 113.918, "Asia/Hong_Kong"),
            ("PEK", "ZBAA", "Beijing Capital", "Beijing", "China", "CN", 40.080, 116.585, "Asia/Shanghai"),
            ("PVG", "ZSPD", "Shanghai Pudong", "Shanghai", "China", "CN", 31.143, 121.805, "Asia/Shanghai"),
            ("CAN", "ZGGG", "Guangzhou Baiyun", "Guangzhou", "China", "CN", 23.392, 113.299, "Asia/Shanghai"),
            ("MFM", "VMMC", "Macau", "Macau", "Macau", "MO", 22.150, 113.592, "Asia/Macau"),
            ("TPE", "RCTP", "Taoyuan", "Taipei", "Taiwan", "TW", 25.077, 121.233, "Asia/Taipei"),
            ("NRT", "RJAA", "Narita", "Tokyo", "Japan", "JP", 35.765, 140.386, "Asia/Tokyo"),
            ("HND", "RJTT", "Haneda", "Tokyo", "Japan", "JP", 35.553, 139.781, "Asia/Tokyo"),
            ("KIX", "RJBB", "Kansai", "Osaka", "Japan", "JP", 34.434, 135.233, "Asia/Tokyo"),
            ("SIN", "WSSS", "Changi", "Singapore", "Singapore", "SG", 1.364, 103.991, "Asia/Singapore"),
            ("BKK", "VTBS", "Suvarnabhumi", "Bangkok", "Thailand", "TH", 13.690, 100.750, "Asia/Bangkok"),
            ("KUL", "WMKK", "Kuala Lumpur", "Kuala Lumpur", "Malaysia", "MY", 2.746, 101.710, "Asia/Kuala_Lumpur"),
            ("LHR", "EGLL", "Heathrow", "London", "United Kingdom", "GB", 51.470, -0.454, "Europe/London"),
            ("CDG", "LFPG", "Charles de Gaulle", "Paris", "France", "FR", 49.010, 2.548, "Europe/Paris"),
            ("JFK", "KJFK", "John F. Kennedy", "New York", "United States", "US", 40.641, -73.778, "America/New_York"),
            ("SFO", "KSFO", "San Francisco", "San Francisco", "United States", "US", 37.619, -122.375, "America/Los_Angeles"),
            ("LAX", "KLAX", "Los Angeles", "Los Angeles", "United States", "US", 33.942, -118.408, "America/Los_Angeles"),
            ("SYD", "YSSY", "Kingsford Smith", "Sydney", "Australia", "AU", -33.946, 151.177, "Australia/Sydney"),
        ]
        var map: [String: Airport] = [:]
        for r in rows {
            map[r.0] = Airport(iata: r.0, icao: r.1, name: r.2, city: r.3, country: r.4, countryCode: r.5,
                               latitude: r.6, longitude: r.7, zoneId: r.8)
        }
        return map
    }()

    private let airlineIcaoByIata: [String: String] = [
        "CX": "CPA", "KA": "HDA", "OZ": "AAR", "KE": "KAL", "CA": "CCA", "MU": "CES", "CZ": "CSN", "HU": "CHH",
        "3U": "CSC", "MF": "CXA", "ZH": "CSZ", "HO": "DKH", "9C": "CQH", "JL": "JAL", "NH": "ANA", "MM": "APJ",
        "GK": "JJP", "SQ": "SIA", "TR": "TGW", "TG": "THA", "BR": "EVA", "CI": "CAL", "MH": "MAS", "AK": "AXM",
        "BA": "BAW", "VS": "VIR", "AF": "AFR", "LH": "DLH", "QF": "QFA", "UA": "UAL", "AA": "AAL", "DL": "DAL",
        "EK": "UAE", "QR": "QTR", "NX": "AMU", "UO": "HKE",
    ]

    func airport(_ iata: String) -> Airport? {
        let code = iata.uppercased()
        if let a = bundled[code] { return a }
        lock.lock(); defer { lock.unlock() }
        return learned[code]
    }

    func airlineIcao(_ iata: String) -> String? { airlineIcaoByIata[iata.uppercased()] }

    /// Fetches an unknown airport once; a failure is not fatal, the code just cannot be placed.
    func ensure(_ iata: String, fetch: () async throws -> Airport) async {
        if airport(iata) != nil { return }
        if let a = try? await fetch() { remember(a) }
    }

    // The lock is taken in a synchronous helper: NSLock may not be used directly from async code.
    private func remember(_ a: Airport) {
        lock.lock(); defer { lock.unlock() }
        learned[a.iata.uppercased()] = a
    }
}
