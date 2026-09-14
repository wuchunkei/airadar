import Foundation
import UIKit

/// The Airadar backend (backend/ in this repo): flight status, accounts, trips,
/// friends, sharing, plans. Same routes the Android app uses.
enum BackendClient {

    struct BackendError: LocalizedError {
        let message: String
        let code: Int
        var errorDescription: String? { message }
    }

    // MARK: - Decoding

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: raw) ?? plain.date(from: raw) { return date }
            // A naive timestamp from the server is UTC.
            if let local = LocalDateTime(string: raw) { return local.date(in: .gmt) }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Flights & airports

    static func flight(_ number: String, on day: String) async throws -> Flight {
        let path = "flights/\(number.uppercased())/\(day)"
        let data: Data
        if await AuthStore.shared.isSignedIn {
            do { data = try await authed("GET", path) } catch let e as BackendError where e.code == 401 {
                data = try await call("GET", path)
            }
        } else {
            data = try await call("GET", path)
        }
        var f = try decoder.decode(Flight.self, from: data)
        await ensureAirports(f.departure, f.arrival)
        f.callsign = f.callsign ?? AirportDatabase.shared.airlineIcao(String(number.prefix(2))).map { $0 + number.dropFirst(2) }
        return f
    }

    static func airport(_ iata: String) async throws -> Airport {
        try decoder.decode(Airport.self, from: try await call("GET", "airports/\(iata.uppercased())"))
    }

    private static func ensureAirports(_ codes: String...) async {
        for c in codes { await AirportDatabase.shared.ensure(c) { try await airport(c) } }
    }

    // MARK: - Account

    private struct TokenPair: Decodable {
        let accessToken: String
        let refreshToken: String
        let user: AuthUser
    }

    @MainActor
    static func signInWithGoogle(idToken: String) async throws -> AuthUser {
        let body = ["idToken": idToken, "device": UIDevice.current.name]
        let pair = try decoder.decode(TokenPair.self, from: try await call("POST", "auth/google", json: body))
        AuthStore.shared.save(accessToken: pair.accessToken, refreshToken: pair.refreshToken, user: pair.user)
        return pair.user
    }

    @MainActor
    static func signOut() async {
        if let token = AuthStore.shared.refreshToken {
            _ = try? await call("POST", "auth/logout", json: ["refreshToken": token])
        }
        AuthStore.shared.clear()
    }

    private static let refreshLock = AsyncLock()

    /// Swaps the refresh token for a new pair; serialised so two 401s cannot both spend it.
    private static func refreshSession() async -> Bool {
        await refreshLock.withLock {
            guard let token = await AuthStore.shared.refreshToken else { return false }
            do {
                let pair = try decoder.decode(TokenPair.self, from: try await call("POST", "auth/refresh", json: ["refreshToken": token]))
                await AuthStore.shared.save(accessToken: pair.accessToken, refreshToken: pair.refreshToken, user: pair.user)
                return true
            } catch let e as BackendError {
                if e.code == 401 { await AuthStore.shared.clear() }
                return false
            } catch { return false }
        }
    }

    private struct Me: Decodable {
        let id: String, email: String, name: String?, avatarUrl: String?, givenName: String?, color: String?
        let findableByEmail: Bool
        let membership: Membership
    }

    @MainActor
    static func me() async throws -> AuthUser {
        let m = try decoder.decode(Me.self, from: try await authed("GET", "me"))
        AuthStore.shared.updateProfile { u in
            u.givenName = m.givenName; u.color = m.color; u.findableByEmail = m.findableByEmail; u.membership = m.membership
            u.name = m.name ?? u.name; u.avatarUrl = m.avatarUrl
        }
        return AuthStore.shared.user!
    }

    @MainActor
    static func updateProfile(findableByEmail: Bool) async throws {
        let m = try decoder.decode(Me.self, from: try await authed("PATCH", "me", json: ["findableByEmail": findableByEmail]))
        AuthStore.shared.updateProfile { $0.findableByEmail = m.findableByEmail; $0.membership = m.membership }
    }

    // MARK: - Plan tokens

    private struct TokenStatus: Decodable { let plan: Tier; let until: Date; let grace: Bool; let boundEmail: String? }

    /// Before sign-in: is this token live, and may this phone use it? Binds the phone on first use.
    @MainActor
    static func checkToken(_ token: String) async throws -> CheckedToken {
        let code = token.trimmingCharacters(in: .whitespaces).lowercased()
        let s = try decoder.decode(TokenStatus.self, from: try await call("POST", "billing/token/check",
                                                                        json: ["token": code, "deviceId": AuthStore.shared.deviceId]))
        let checked = CheckedToken(token: code, tier: s.plan, until: s.until, boundEmail: s.boundEmail)
        AuthStore.shared.saveCheckedToken(checked)
        return checked
    }

    /// After sign-in: ties the token to this account (first come) and raises the plan.
    @MainActor
    static func redeem(_ token: String) async throws -> Membership {
        let m = try decoder.decode(Membership.self, from: try await authed("POST", "billing/redeem",
                                                                          json: ["token": token.lowercased(), "deviceId": AuthStore.shared.deviceId]))
        AuthStore.shared.saveMembership(m)
        return m
    }

    // MARK: - Trips

    static func listTrips(deleted: Bool = false) async throws -> [Flight] {
        let list = try decoder.decode([Flight].self, from: try await authed("GET", deleted ? "trips/deleted" : "trips"))
        for f in list { await ensureAirports(f.departure, f.arrival) }
        return list
    }

    static func putTrip(_ flight: Flight) async throws {
        var wire = flight
        wire.sharedBy = nil; wire.shares = []; wire.deletedAt = nil; wire.typicalDurationMinutes = nil
        _ = try await authed("PUT", "trips/\(flight.id)", body: try encoder.encode(wire))
    }

    static func deleteTrip(_ id: String) async throws { _ = try await authed("DELETE", "trips/\(id)") }
    static func restoreTrip(_ id: String) async throws { _ = try await authed("POST", "trips/\(id)/restore") }

    // MARK: - People and shares

    static func lookup(email: String) async throws -> Person {
        let q = email.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try decoder.decode(Person.self, from: try await authed("GET", "users/lookup?email=\(q)"))
    }

    static func friends() async throws -> [Friend] { try decoder.decode([Friend].self, from: try await authed("GET", "friends")) }

    static func requestFriend(_ userId: String) async throws -> Friend {
        try decoder.decode(Friend.self, from: try await authed("POST", "friends/request", json: ["userId": userId]))
    }

    static func acceptFriend(_ id: String) async throws { _ = try await authed("POST", "friends/\(id)/accept") }
    static func removeFriend(_ id: String) async throws { _ = try await authed("DELETE", "friends/\(id)") }

    private struct ShareOut: Decodable {
        let id: String, tripId: String, status: ShareStatus, kind: String, url: String?, person: Person?
    }

    /// Shares with a friend; with no recipient a link is minted and its URL returned.
    static func shareTrip(_ tripId: String, to userId: String? = nil) async throws -> (share: TripShare?, url: String?) {
        var body: [String: Any] = [:]
        if let userId { body["toUserId"] = userId }
        let s = try decoder.decode(ShareOut.self, from: try await authed("POST", "trips/\(tripId)/share", json: body))
        let share = s.person.map { TripShare(id: s.id, person: $0, status: s.status) }
        return (share, s.url)
    }

    /// Friend shares of my trips: tripId → shares.
    static func outgoingShares() async throws -> [String: [TripShare]] {
        let rows = try decoder.decode([ShareOut].self, from: try await authed("GET", "shares/outgoing"))
        var map: [String: [TripShare]] = [:]
        for r in rows { if let p = r.person { map[r.tripId, default: []].append(TripShare(id: r.id, person: p, status: r.status)) } }
        return map
    }

    private struct IncomingShare: Decodable {
        let id: String, status: ShareStatus, person: Person?, trip: Flight
    }

    /// Friends' trips shared with me, each carrying who shared it and my answer so far.
    static func incomingShares() async throws -> [Flight] {
        let rows = try decoder.decode([IncomingShare].self, from: try await authed("GET", "shares/incoming"))
        var out: [Flight] = []
        for r in rows {
            guard let p = r.person else { continue }
            await ensureAirports(r.trip.departure, r.trip.arrival)
            var f = r.trip
            f.id = "shared:\(r.id)"
            f.sharedBy = TripShare(id: r.id, person: p, status: r.status)
            f.deletedAt = nil
            out.append(f)
        }
        return out
    }

    static func respondToShare(_ id: String, action: String) async throws {
        _ = try await authed("POST", "shares/\(id)/respond", json: ["action": action])
    }

    struct LinkedTrip: Sendable { let flight: Flight; let owner: Person; let ownerName: String }
    private struct LinkedOut: Decodable { let trip: Flight; let owner: Person; let ownerName: String? }

    /// What a shared link points at; needs no sign-in.
    static func linkedTrip(_ token: String) async throws -> LinkedTrip {
        let o = try decoder.decode(LinkedOut.self, from: try await call("GET", "shares/link/\(token)"))
        await ensureAirports(o.trip.departure, o.trip.arrival)
        return LinkedTrip(flight: o.trip, owner: o.owner, ownerName: o.ownerName ?? o.owner.givenName)
    }

    static func copyLinkedTrip(_ token: String) async throws -> Flight {
        try decoder.decode(Flight.self, from: try await authed("POST", "shares/link/\(token)/copy"))
    }

    // MARK: - Transport

    /// A signed-in call: retried once with a fresh access token after a 401.
    private static func authed(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil) async throws -> Data {
        guard let first = await AuthStore.shared.accessToken else { throw BackendError(message: "Sign in required.", code: 401) }
        do {
            return try await call(method, path, json: json, body: body, bearer: first)
        } catch let e as BackendError where e.code == 401 {
            guard await refreshSession(), let next = await AuthStore.shared.accessToken else { throw e }
            return try await call(method, path, json: json, body: body, bearer: next)
        }
    }

    private static func call(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil, bearer: String? = nil) async throws -> Data {
        guard Config.isBackendConfigured, let url = URL(string: "\(Config.backendURL)/\(path)") else {
            throw BackendError(message: "Backend address missing — set BACKEND_URL in Config.xcconfig.", code: 0)
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        if !Config.backendToken.isEmpty { req.setValue(Config.backendToken, forHTTPHeaderField: "X-Airadar-Token") }
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) } catch {
            throw BackendError(message: "Could not reach the Airadar server: \(error.localizedDescription)", code: 0)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { return data.isEmpty ? Data("{}".utf8) : data }

        // FastAPI wraps errors as {"detail": ...}; ours carry an object with "error".
        var reason = ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = obj["detail"] as? [String: Any] { reason = (d["error"] as? String) ?? "\(d)" }
            else if let d = obj["detail"] as? String { reason = d }
        }
        let message: String
        switch code {
        case 401: message = reason.isEmpty ? "The server rejected this build's token (BACKEND_TOKEN)." : reason
        case 402: message = reason.isEmpty ? "This needs a higher plan." : reason
        case 403: message = reason.isEmpty ? "Not allowed." : reason
        case 404: message = path.hasPrefix("flights/") ? "Nothing found for that flight on that date." : (reason.isEmpty ? "Not found." : reason)
        case 429: message = "AirLabs monthly quota used up on the server."
        default: message = reason.isEmpty ? "Airadar server error (HTTP \(code))." : reason
        }
        throw BackendError(message: message, code: code)
    }
}

/// An actor-backed mutex for the one place two tasks must not overlap.
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async -> T) async -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if let next = waiters.first { waiters.removeFirst(); next.resume() } else { busy = false }
        }
        return await body()
    }
}
