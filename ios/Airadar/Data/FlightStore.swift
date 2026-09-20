import Foundation
import Combine

/// In-memory source of truth shared by every screen. Signed in, it mirrors the
/// account on the server; signed out, it holds only this session's additions and
/// starts empty.
@MainActor
final class FlightStore: ObservableObject {
    static let shared = FlightStore()

    /// How long a deleted trip waits in the recycle bin before it is gone for good.
    static let retentionDays = 30

    @Published private(set) var flights: [Flight] = [] {
        // The Home Screen icon follows the tier this recomputes to — a
        // no-op call whenever it hasn't actually changed (AppIconManager
        // checks before ever touching UIApplication).
        didSet { AppIconManager.apply(tierStanding.tier) }
    }
    @Published private(set) var deleted: [Flight] = []
    /// The last plan refusal, for the UI to explain and offer an upgrade.
    @Published var limitHit: LimitReached?

    // Everything, deleted trips included; the two lists above are its two halves.
    private var all: [Flight] = []

    private var synced: Bool { AuthStore.shared.isSignedIn }

    /// A flight within a day and a half of now: worth polling for status.
    var hasFlightNearNow: Bool {
        let now = Date()
        return flights.contains { f in
            guard let dep = f.departureInstant else { return false }
            return abs(dep.timeIntervalSince(now)) < 36 * 3600
        }
    }

    /// Every leg actually flown (or in the air right now) — what the
    /// milestone tiers count against. The same filter My's own map uses for
    /// its route network, kept in one place so the two never drift apart.
    var completedFlights: [Flight] {
        flights.filter { ($0.phase == .past || $0.phase == .inProgress) && !$0.isPending }
    }
    var completedFlightCount: Int { completedFlights.count }

    /// Where the tier ladder puts this traveller right now.
    var tierStanding: TierStanding { .compute(for: completedFlights) }

    /// Porcelain's sequence number, once claimed — "the Nth traveller here".
    /// Never set locally: only the backend hands one out, and only once
    /// standing genuinely reads Porcelain.
    @Published private(set) var porcelainRank: Int?

    /// Safe to call any time standing is checked: an existing claim just
    /// comes back unchanged, so there's no harm calling this opportunistically.
    func refreshPorcelainRank() async {
        guard tierStanding.tier == .porcelain, AuthStore.shared.isSignedIn else { return }
        porcelainRank = try? await BackendClient.claimPorcelain()
    }

    // The last published list, on disk, so a relaunch shows the trips at once and
    // the server sync only refines them.
    nonisolated private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trips.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? BackendClient.decoder.decode([Flight].self, from: data) {
            publish(cached)
        }
    }

    private func persist() {
        let snapshot = all
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            if let data = try? BackendClient.encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Pull-to-refresh: the account's trips when signed in, a re-publish otherwise.
    func refresh() async {
        if synced { try? await syncFromServer() } else { publish(all) }
    }

    /// Replaces everything with what the account holds. Called at sign-in and on refresh.
    func syncFromServer() async throws {
        let outgoing = (try? await BackendClient.outgoingShares()) ?? [:]
        var live = try await BackendClient.listTrips()
        for i in live.indices { live[i].shares = outgoing[live[i].id] ?? [] }
        let binned = try await BackendClient.listTrips(deleted: true)
        let incoming = (try? await BackendClient.incomingShares()) ?? []

        // A trip taken "together" is mine now (the server copied it); the friend's
        // name rides on my copy instead of a second card.
        let together = incoming.filter { $0.sharedBy?.status == .together }
        var mine = live
        for i in mine.indices {
            if let t = together.first(where: { $0.flightNumber == mine[i].flightNumber && $0.departureTime == mine[i].departureTime }) {
                mine[i].sharedBy = t.sharedBy
            }
        }
        let rest = incoming.filter { inc in
            !(inc.sharedBy?.status == .together &&
              live.contains { $0.flightNumber == inc.flightNumber && $0.departureTime == inc.departureTime })
        }
        // What moved since the last look — a delay, a gate, a status — is announced.
        let before = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        for f in mine { if let old = before[f.id] { FlightReminders.announceChange(from: old, to: f) } }
        publish(mine + binned + rest)
        for f in mine where f.phase == .upcoming { SiriSuggestions.donate(f) }
    }

    /// Back to the signed-out list: empty.
    func onSignedOut() {
        all = []
        publish(all)
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    private func push(_ block: @escaping @Sendable () async throws -> Void) {
        guard synced else { return }
        Task { try? await block() }
    }

    /// Adds a trip; returns false (and records why) when the plan does not allow it.
    @discardableResult
    func add(_ flight: Flight) -> Bool {
        let same = all.first { $0.flightNumber == flight.flightNumber && $0.departureTime == flight.departureTime }
        if same == nil {
            do { try Entitlements.checkAdd(flight, existing: all) } catch {
                limitHit = error
                return false
            }
        }
        if let same {
            // Adding a trip that sits in the bin brings it back rather than duplicating it.
            if same.deletedAt != nil { restore(same.id) }
            return true
        }
        publish(all + [flight])
        SiriSuggestions.donate(flight)
        if synced {
            Task { [weak self] in
                do {
                    let stored = try await BackendClient.putTrip(flight)
                    // A fresh fed flight (see Flight.feedStatus) gets its real
                    // review outcome back in this same response — reflect it
                    // at once, rather than leaving the card reading "pending"
                    // until whatever's next syncs from the server.
                    guard let self, stored.feedStatus != flight.feedStatus else { return }
                    self.publish(self.all.map { $0.id == stored.id ? stored : $0 })
                } catch let e as BackendClient.BackendError where e.code == 402 {
                    // The server's count is the truth; take the trip back out.
                    guard let self else { return }
                    self.publish(self.all.filter { $0.id != flight.id })
                    self.limitHit = LimitReached(reason: e.message, tier: Entitlements.membership.tier)
                } catch {}
            }
        }
        return true
    }

    func confirm(_ flight: Flight) {
        // A `let` copy: a @Sendable closure may not capture a `var`.
        let confirmed = flight.confirmed()
        publish(all.map { $0.id == flight.id ? confirmed : $0 })
        SiriSuggestions.donate(confirmed)
        push { try await BackendClient.putTrip(confirmed) }
    }

    func replace(_ old: Flight, with replacement: Flight) {
        let confirmed = replacement.confirmed()
        let oldId = old.id
        publish(all.filter { $0.id != oldId } + [confirmed])
        push {
            if oldId != confirmed.id { try await BackendClient.deleteTrip(oldId) }
            try await BackendClient.putTrip(confirmed)
        }
    }

    /// Moves the trip to the recycle bin; a friend's shared trip is declined instead.
    func delete(_ id: String) {
        if id.hasPrefix("shared:"), let share = all.first(where: { $0.id == id })?.sharedBy {
            publish(all.filter { $0.id != id })
            push { try await BackendClient.respondToShare(share.id, action: "reject") }
            return
        }
        publish(all.map { var f = $0; if f.id == id { f.deletedAt = Date() }; return f })
        SiriSuggestions.forget(id)
        push { try await BackendClient.deleteTrip(id) }
    }

    /// Every current trip, one at a time — the same as swiping each away, all
    /// at once: a real trip goes to the Recycle Bin, a friend's shared one is
    /// just declined, exactly as a single delete already does either way.
    func deleteAll() {
        for f in flights { delete(f.id) }
    }

    func restore(_ id: String) {
        publish(all.map { var f = $0; if f.id == id { f.deletedAt = nil }; return f })
        push { try await BackendClient.restoreTrip(id) }
    }

    func setTrack(_ id: String, points: [TrackPoint], flownOn: String, icao24: String? = nil) {
        publish(all.map { var f = $0; if f.id == id { f.track = points; f.trackFlownOn = flownOn }; return f })
        if let updated = all.first(where: { $0.id == id }) { push { try await BackendClient.putTrip(updated) } }
        // The airframe's own hex, from the track just fetched — worth a free,
        // one-off aircraft-type lookup if the trip doesn't already have one.
        if let icao24, all.first(where: { $0.id == id })?.aircraft == nil {
            Task { await self.fillAircraft(id, icao24: icao24) }
        }
    }

    /// adsbdb, keyed by Mode-S hex — free, and separate from AeroDataBox's
    /// quota entirely. Only ever fills a gap, never overwrites a real value.
    private func fillAircraft(_ id: String, icao24: String) async {
        guard let found = try? await AdsbdbClient.shared.aircraft(modeS: icao24),
              let type = found.type ?? found.icaoType else { return }
        publish(all.map { f in var g = f; if g.id == id, g.aircraft == nil { g.aircraft = type }; return g })
        if let updated = all.first(where: { $0.id == id }) { push { try await BackendClient.putTrip(updated) } }
    }

    /// A callsign adsbdb resolved that the trip didn't already have — the
    /// static bundled table only knows a few dozen airlines; this reaches any
    /// of them. Filled in and synced like a track is, so it is asked for once.
    func applyCallsign(_ id: String, callsign: String) {
        publish(all.map { f in var g = f; if g.id == id, g.callsign == nil { g.callsign = callsign }; return g })
        if let updated = all.first(where: { $0.id == id }) { push { try await BackendClient.putTrip(updated) } }
    }

    /// Accept, reject or take together a friend's trip; the list is then refreshed.
    func respondToShare(_ flight: Flight, action: String) async throws {
        guard let share = flight.sharedBy else { return }
        try await BackendClient.respondToShare(share.id, action: action)
        try await syncFromServer()
    }

    /// Shares one of my trips with a friend and shows the new block straight away.
    func share(_ flight: Flight, with person: Person) async throws {
        let (share, _) = try await BackendClient.shareTrip(flight.id, to: person.id)
        guard let share else { return }
        publish(all.map { f in
            guard f.id == flight.id else { return f }
            var g = f
            g.shares = g.shares.filter { $0.person.id != person.id } + [share]
            return g
        })
    }

    private func publish(_ list: [Flight]) {
        let expiry = Date().addingTimeInterval(-Double(Self.retentionDays) * 86400)
        let live = list.filter { $0.deletedAt == nil }
        all = list
            .filter { !($0.deletedAt.map { $0 < expiry } ?? false) }
            .map { var f = $0; f.typicalDurationMinutes = typicalDuration(f, pool: live); return f }
        flights = all.filter { $0.deletedAt == nil }.sorted { ($0.departureInstant ?? .distantFuture) < ($1.departureInstant ?? .distantFuture) }
        deleted = all.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        persist()
        LiveActivities.sync(flights)
        WatchSync.shared.sync(flights)
    }

    /// Average block time over the last week of the same number, else the scheduled duration.
    private func typicalDuration(_ flight: Flight, pool: [Flight]) -> Int {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let recent = pool.filter {
            $0.flightNumber == flight.flightNumber && $0.phase == .past && ($0.departureInstant ?? .distantPast) > cutoff
        }
        if recent.isEmpty { return flight.durationMinutes }
        return recent.reduce(0) { $0 + $1.durationMinutes + $1.delayMinutes } / recent.count
    }
}

private extension Flight {
    func confirmed() -> Flight { var f = self; f.isPending = false; return f }
}
