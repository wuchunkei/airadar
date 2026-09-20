import SwiftUI
import CoreLocation

/// The bottom sheet for one flight: a map thumbnail, airline and status, the big
/// airport codes, times (a delay shows the original struck through), the facts,
/// and whatever actions the caller adds.
struct FlightDetailSheet<Actions: View>: View {
    @EnvironmentObject private var store: FlightStore
    let flight: Flight
    var forceSystemZone = false
    var trackStatus: TrackStatus? = nil
    var onLoadTrack: (() -> Void)? = nil
    /// The aircraft's real position while it flies, asked every 5 minutes the sheet is open.
    @State private var live: LivePosition?
    /// Every live fix collected this way since the sheet opened -- a real,
    /// if short, breadcrumb trail for a flight OpenSky's own track fetch
    /// hasn't (yet, or ever) answered for. Genuinely reported positions,
    /// never the schedule's own estimate -- that's what the plain arc with
    /// a progress cut is for, and only shown while this stays too short to
    /// draw on its own.
    @State private var liveTrail: [TrackPoint] = []
    /// Learned once (from whichever of adsb.lol/OpenSky answers first) and
    /// kept for the rest of this session, so OpenSky's own live lookup can
    /// use its cheap icao24 filter on every later poll instead of the
    /// bounding-box scan finding it the first time needs.
    @State private var knownHex: String?
    /// The backend's own answer for this exact flight (AirLabs, AeroDataBox
    /// behind it), asked once and cached on device from then on — fills in a
    /// terminal, gate or aircraft type this trip didn't already have; never
    /// overwrites one it did. Every key involved lives on the server.
    @State private var enrichedFlight: Flight?
    /// A callsign the trip didn't have, resolved via adsbdb — used for the rest
    /// of this session even before the store's own copy catches up.
    @State private var resolvedCallsign: String?
    /// Whether adsbdb has already had its chance at a missing callsign — so
    /// "still nil" only counts as truly exhausted once that has actually happened.
    @State private var callsignResolutionAttempted = false
    /// adsbdb's free aircraft lookup, from the live position's own hex —
    /// separate from AeroDataBox's quota, and this is the one place a photo shows.
    @State private var adsbdbAircraft: AdsbdbClient.Aircraft?
    /// Where this same airframe flew in from, if OpenSky's own per-aircraft
    /// history has anything recent -- a courtesy note, not a fact this trip
    /// itself carries.
    @State private var previousFlight: OpenSkyClient.PreviousFlight?
    /// Whether a real driving route to the departure airport exists from here
    /// -- only checked inside the last 24h before departure, since that's the
    /// only window "tap to navigate" actually matters in.
    @State private var routeValid = false
    @State private var showMapChooser = false
    let onDismiss: () -> Void
    var primaryAction: (label: String, action: () -> Void)? = nil
    /// Under the primary one, quieter — "Incorrect" beneath "Correct".
    var secondaryAction: (label: String, action: () -> Void)? = nil
    @ViewBuilder var extraActions: () -> Actions

    /// Measured content height: the sheet opens just tall enough, not full screen.
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TileMapView(routes: routes, tracks: mapTracks, interactive: false, cityLabels: true, livePlane: live)
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 16))

                header
                codes
                if let note = previousFlightNote {
                    Label(note, systemImage: "arrow.uturn.backward.circle").font(.caption).foregroundStyle(.secondary)
                }
                if let url = adsbdbAircraft?.photoURL { aircraftPhoto(url) }
                facts
                extraActions()
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // The main action sits at the very bottom, whatever the sheet's height.
        .safeAreaInset(edge: .bottom) {
            if primaryAction != nil || secondaryAction != nil {
                VStack(spacing: 10) {
                    if let primary = primaryAction {
                        Button(action: primary.action) {
                            Text(primary.label).fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    if let secondary = secondaryAction {
                        Button(action: secondary.action) {
                            Text(secondary.label).fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glass).tint(.red)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        // No ATC callsign yet: the bundled ~35-airline table missed this one at
        // import time — adsbdb reaches any airline it knows, so it gets asked
        // once and, once found, is synced like any other trip detail.
        .task(id: flight.id) {
            defer { callsignResolutionAttempted = true }
            guard flight.callsign == nil else { return }
            if let found = try? await AdsbdbClient.shared.icaoCallsign(forFlightNumber: flight.flightNumber) {
                resolvedCallsign = found
                store.applyCallsign(flight.id, callsign: found)
            }
        }
        // In the air: where the aircraft really is, refreshed every 5 minutes --
        // adsb.lol and OpenSky polled together once the hex is known (each
        // misses a real fraction of the time; whichever answers on a given
        // cycle covers for the other), adsb.lol alone tried first while it
        // isn't, OpenSky's own bounding-box scan only as the fallback to
        // learn it at all.
        .task(id: "\(flight.id)|\(callsign ?? "")") {
            guard let callsign else { return }
            while !Task.isCancelled, flight.phase == .inProgress {
                var fix: LivePosition?
                if let hex = knownHex {
                    async let fromAdsbLol = LivePositionClient.shared.position(callsign: callsign)
                    async let fromOpenSky = OpenSkyClient.shared.liveState(icao24: hex)
                    let (a, b) = await (fromAdsbLol, fromOpenSky)
                    fix = a ?? b
                } else {
                    fix = await LivePositionClient.shared.position(callsign: callsign)
                    if fix == nil, let origin = flight.departureAirport, let destination = flight.arrivalAirport {
                        fix = await OpenSkyClient.shared.liveState(callsign: callsign, origin: origin, destination: destination)
                    }
                }
                if let fix {
                    live = fix
                    if knownHex == nil { knownHex = fix.hex }
                    let point = TrackPoint(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude, time: fix.seenAt)
                    if liveTrail.last?.lat != point.lat || liveTrail.last?.lon != point.lon { liveTrail.append(point) }
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
        // OpenSky gets the first shot at a real track — quietly, the way it
        // always has -- but only once the flight has actually left the
        // ground. A flight that hasn't departed yet always shows the plain
        // arc, never a borrowed track from some past occurrence of the same
        // route (that borrowed track could itself be an incomplete or
        // diverted flight, which reads as a broken route for a trip that
        // hasn't even happened).
        .task(id: "\(flight.id)|\(callsign ?? "")") {
            if flight.trackFlownOn == nil, callsign != nil, flight.phase != .upcoming { onLoadTrack?() }
        }
        // The backend's own lookup only gets asked once OpenSky has had its
        // shot and failed (or can't even be tried — no ATC callsign at all):
        // AeroDataBox behind it is quota-limited, so it stays a fallback, not
        // a first resort.
        .task(id: enrichmentTrigger) {
            guard enrichmentTrigger.exhausted else { return }
            await loadEnrichment()
        }
        // The live fix's own hex, once there is one — adsbdb's aircraft lookup
        // is free and separate from AeroDataBox, so this never waits on that quota.
        .task(id: live?.hex) {
            guard let hex = live?.hex else { return }
            adsbdbAircraft = try? await AdsbdbClient.shared.aircraft(modeS: hex)
        }
        // A courtesy note, not a fact about this flight -- purely "this
        // airframe flew in from somewhere not long ago", useful context for
        // why an on-time departure might slip. Only ever attempted once a
        // hex is known, same as the aircraft photo above.
        .task(id: live?.hex) {
            guard let hex = live?.hex else { return }
            previousFlight = try? await OpenSkyClient.shared.previousFlight(icao24: hex, before: flight.departureInstant ?? Date())
        }
        // The Share button's own map snapshot is the slow part of that flow
        // (a real MKMapSnapshotter fetch) -- ShareImage.warm exists exactly
        // to pre-fetch it, but nothing was actually calling it until the
        // button itself was tapped. Starting it here, the moment this sheet
        // opens, gives it the traveller's whole time looking at the sheet as
        // a head start, so the tap that matters lands on an already-warm
        // cache instead of a cold one. Cheap either way: it's keyed by route
        // and never touches the server, so warming it for a sheet that never
        // gets shared costs nothing but a map tile fetch.
        .task(id: "\(flight.departure)-\(flight.arrival)") {
            await ShareImage.warm(flight)
        }
        // Same idea for the share link itself: creating one is idempotent on
        // the server (an existing link share for this trip is just handed
        // back, never duplicated), so asking for it here costs nothing and
        // means the real tap's own call finds it already minted -- a fast
        // lookup instead of a fresh insert. Only for a trip that's actually
        // mine to share -- a friend's shared-in trip never shows the Share
        // button at all, so there's nothing worth warming for it.
        .task(id: flight.id) {
            guard flight.sharedBy == nil else { return }
            _ = try? await BackendClient.shareTrip(flight.id)
        }
        // Only worth asking inside the last day before departure -- any
        // earlier and "can I drive there right now" isn't the traveller's
        // question yet, and the fix only means anything for a trip that
        // hasn't left. A denied/no-fix location or no drivable route both
        // just leave the code its ordinary colour, never a false blue.
        .task(id: flight.id) {
            routeValid = false
            guard flight.phase == .upcoming, let airport = flight.departureAirport,
                  let departs = flight.departureInstant,
                  departs.timeIntervalSinceNow > 0, departs.timeIntervalSinceNow < 86_400 else { return }
            routeValid = await RouteValidity.hasDrivableRoute(to: airport)
        }
        .confirmationDialog("Navigate to \(flight.departure)", isPresented: $showMapChooser, titleVisibility: .visible) {
            ForEach(MapProvider.available) { provider in
                Button(provider.label) {
                    if let airport = flight.departureAirport { provider.open(to: airport) }
                }
            }
        }
    }

    /// `flight.callsign` for the rest of this session, or whatever adsbdb just
    /// resolved — the store's own copy of `flight` will not reflect the update
    /// until the sheet is reopened, but nothing here should have to wait for that.
    private var callsign: String? { flight.callsign ?? resolvedCallsign }

    private struct EnrichmentTrigger: Equatable { let flightId: String; let exhausted: Bool }
    private var enrichmentTrigger: EnrichmentTrigger {
        let noCallsignAtAll = callsign == nil && callsignResolutionAttempted
        return .init(flightId: flight.id, exhausted: noCallsignAtAll || trackStatus?.isFailure == true)
    }

    private func loadEnrichment() async {
        if let cached = FlightLookupCache.shared.result(for: flight.id) { enrichedFlight = cached; return }
        let found = try? await BackendClient.flight(flight.flightNumber, on: flight.departureDay)
        FlightLookupCache.shared.remember(flight.id, found)
        enrichedFlight = found
    }

    /// Just tall enough for the content; only content that does not fit on one
    /// screen can be pulled up to full height.
    private var detents: Set<PresentationDetent> {
        let fitted = contentHeight + footerHeight
        guard fitted > 0 else { return [.large] }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let screen = scene?.screen.bounds.height ?? 844
        return fitted < screen * 0.88 ? [.height(fitted)] : [.height(screen * 0.88), .large]
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(flight.airlineName.isEmpty ? "Airline" : flight.airlineName).font(.headline)
                Text(flight.flightNumber).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("Status").font(.caption).foregroundStyle(.secondary)
                Text(flight.displayStatus.label).fontWeight(.semibold).foregroundStyle(flight.displayStatus.color)
            }
        }
    }

    private var codes: some View {
        HStack(spacing: 12) {
            // Only the departure code is a navigation target -- tapping the
            // arrival code to navigate somewhere the traveller isn't yet
            // would just be confusing. Blue exactly when a real drivable
            // route was found, in the same last-24h window it was checked in.
            BigCode(code: flight.departure, terminal: flight.departureTerminal ?? enrichedFlight?.departureTerminal,
                    gate: flight.departureGate ?? enrichedFlight?.departureGate, city: flight.departureAirport?.cityCountry,
                    trailing: false, highlighted: routeValid,
                    onTap: routeValid ? { showMapChooser = true } : nil)
            // The way between: an arrow before departure, the plane along a dashed line in the air, done after.
            FlightProgressLine(flight: flight).frame(maxWidth: .infinity).frame(height: 18)
            BigCode(code: flight.arrival, terminal: flight.arrivalTerminal ?? enrichedFlight?.arrivalTerminal,
                    gate: flight.arrivalGate ?? enrichedFlight?.arrivalGate, city: flight.arrivalAirport?.cityCountry, trailing: true)
        }
    }

    /// The actual airframe, if adsbdb had a photo of it — a real plane, not a
    /// stock shot of the type. Only ever shown while it's live-tracked (that's
    /// the only time a hex is known here), so it's gone once the flight lands.
    private func aircraftPhoto(_ url: URL) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color(.tertiarySystemFill)
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 12))
    }

    private var facts: some View {
        let dep = flight.shownTime(arrival: false, forceSystemZone: forceSystemZone)
        let arr = flight.shownTime(arrival: true, forceSystemZone: forceSystemZone)
        let depValue = dep.clock + " " + dep.zone
        let arrValue = arr.clock + " " + arr.zone
        return VStack(spacing: 10) {
            DetailRow(label: "Departing", value: depValue, secondary: longDay(flight.departureDay), superseded: dep.original)
            DetailRow(label: "Arriving", value: arrValue, secondary: longDay(flight.arrivalTime.dayString), superseded: arr.original)
            DetailRow(label: "Duration", value: formatDuration(flight.durationMinutes))
            DetailRow(label: "Distance", value: formatDistance(flight.distanceKm))
            if let a = flight.aircraft ?? enrichedFlight?.aircraft ?? adsbdbAircraft?.type { DetailRow(label: "Aircraft", value: a) }
            if let reg = adsbdbAircraft?.registration { DetailRow(label: "Registration", value: reg) }
            // Belt numbers appear close to landing; the row is always there.
            DetailRow(label: "Baggage claim", value: flight.baggageClaim ?? "–")
            if let p = flight.pnr { DetailRow(label: "Booking reference", value: p) }
            if let s = flight.sharedBy { DetailRow(label: "Shared by", value: s.person.givenName, secondary: s.status.label) }
        }
    }

    /// "Landed from ZBAA 3h ago" -- the ICAO code as-is, since resolving it to
    /// a city needs an ICAO-keyed lookup this app doesn't carry; still useful
    /// context on its own.
    private var previousFlightNote: String? {
        guard let p = previousFlight, let from = p.fromICAO else { return nil }
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .short
        return "Landed from \(from) " + ago.localizedString(for: p.landedAt, relativeTo: Date())
    }

    /// The actual reported points to draw, if there are any yet -- the
    /// downloaded historical track once OpenSky has answered, or (until
    /// then, or if it never does) this session's own live-polled breadcrumb
    /// trail, real fixes rather than the schedule's own estimate. Empty
    /// while neither exists, which is when `routes`' plain arc takes over.
    private var mapTracks: [MapTrack] {
        // A flight that hasn't departed always shows the plain arc, never a
        // track -- even a stale one stored from before this rule existed.
        guard flight.phase != .upcoming, let a = flight.departureAirport, let b = flight.arrivalAirport else { return [] }
        if let track = flight.track, track.count >= 2 {
            // The one-time historical fetch on its own goes stale the moment
            // it lands (trackFlownOn turning non-null stops it from ever
            // being asked for again) -- so for a flight still in the air,
            // whatever this session's own live poll has collected SINCE the
            // stored track's own last point is appended, keeping the line
            // itself growing all the way from departure to right now,
            // not just the plane marker (which livePlane already refreshes
            // on its own regardless).
            var points = track
            if flight.phase == .inProgress, let lastStored = track.compactMap(\.time).max() {
                points += liveTrail.filter { ($0.time ?? .distantPast) > lastStored }
            }
            return [MapTrack(from: a, to: b, points: Self.gapFilled(points), live: flight.phase == .inProgress)]
        }
        if liveTrail.count >= 2 {
            return [MapTrack(from: a, to: b, points: Self.gapFilled(liveTrail), live: true)]
        }
        return []
    }

    /// Bridges a gap between two consecutive real points with a bowed arc
    /// instead of a straight line -- confirmed a real, not hypothetical,
    /// need: OpenSky's own historical track for a genuinely airborne
    /// aircraft, tested live, had a 9.7-minute hole where every position
    /// call came back empty. A gap wider than 2.5x the 5-minute poll
    /// interval means neither live source answered for at least one whole
    /// cycle -- the interpolated points carry no time of their own, so
    /// they're never mistaken for another real fix by anything reading them.
    private static func gapFilled(_ points: [TrackPoint]) -> [TrackPoint] {
        guard points.count >= 2 else { return points }
        var out: [TrackPoint] = [points[0]]
        for i in 1..<points.count {
            let prev = points[i - 1], next = points[i]
            if let t1 = prev.time, let t2 = next.time, t2.timeIntervalSince(t1) > 750 {
                let bridge = TileMapView.arcPath(from: CLLocationCoordinate2D(latitude: prev.lat, longitude: prev.lon),
                                                 to: CLLocationCoordinate2D(latitude: next.lat, longitude: next.lon), rank: 0)
                out += bridge.dropFirst().dropLast().map { TrackPoint(lat: $0.latitude, lon: $0.longitude) }
            }
            out.append(next)
        }
        return out
    }

    /// The plain bowed arc, with a progress cut for an in-progress flight --
    /// only shown at all while `mapTracks` has nothing real to draw instead.
    private var routes: [MapRoute] {
        guard mapTracks.isEmpty, let a = flight.departureAirport, let b = flight.arrivalAirport else { return [] }
        let progress: Double? = flight.phase == .inProgress ? flight.fractionFlown : nil
        return [MapRoute(from: a, to: b, rank: 0, isReturn: false, progress: progress)]
    }

    private func longDay(_ day: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .gmt
        guard let d = f.date(from: day) else { return day }
        let out = DateFormatter(); out.dateFormat = "EEE, d MMM"; out.locale = Locale(identifier: "en_US"); out.timeZone = .gmt
        return out.string(from: d)
    }
}

extension FlightDetailSheet where Actions == EmptyView {
    init(flight: Flight, forceSystemZone: Bool = false, trackStatus: TrackStatus? = nil, onLoadTrack: (() -> Void)? = nil,
         onDismiss: @escaping () -> Void, primaryAction: (label: String, action: () -> Void)? = nil,
         secondaryAction: (label: String, action: () -> Void)? = nil) {
        self.init(flight: flight, forceSystemZone: forceSystemZone, trackStatus: trackStatus, onLoadTrack: onLoadTrack,
                  onDismiss: onDismiss, primaryAction: primaryAction, secondaryAction: secondaryAction, extraActions: { EmptyView() })
    }
}

private struct BigCode: View {
    let code: String, terminal: String?, gate: String?, city: String?, trailing: Bool
    var highlighted: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        let content = VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(city ?? "").font(.caption).foregroundStyle(.secondary)
            Text(code).font(.system(size: 40, weight: .bold))
                .foregroundStyle(highlighted ? Color(red: 0.043, green: 0.435, blue: 0.831) : .primary)
            if terminal != nil || gate != nil {
                Text([terminal.map { "Terminal \(normalizeTerminal($0))" }, gate.map { "Gate \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let onTap {
            Button(action: onTap) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var secondary: String? = nil
    /// An earlier figure this value replaced — shown struck through beside it.
    var superseded: String? = nil

    var body: some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 6) {
                    if let superseded { Text(superseded).strikethrough().foregroundStyle(.secondary) }
                    Text(value).fontWeight(.semibold).foregroundStyle(superseded != nil ? FlightStatus.delayed.color : .primary)
                }
                if let secondary { Text(secondary).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// The same line as on the lock screen: arrow → before departure; in the air a
/// dashed line, the flown share green with the plane at its head; a full green
/// line once landed.
struct FlightProgressLine: View {
    let flight: Flight

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, midY = g.size.height / 2
            switch flight.phase {
            case .upcoming:
                Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: w - 6, y: midY)) }
                    .stroke(Color.secondary, lineWidth: 1.5)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .position(x: w - 4, y: midY)
            case .inProgress, .past:
                let f = flight.phase == .past ? 1 : flight.fractionFlown
                // Flying: green, the same colour the map's own live plane
                // and track use. Finished: blue, matching a completed
                // trip's own route line -- no longer "in progress" green
                // once it's actually done.
                let tint = flight.phase == .past
                    ? Color(red: 0.043, green: 0.435, blue: 0.831)
                    : Color(red: 0.20, green: 0.70, blue: 0.30)
                Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: w - 8, y: midY)) }
                    .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: (w - 8) * f, y: midY)) }
                    .stroke(tint, lineWidth: 2)
                Circle().fill(Color.secondary).frame(width: 6, height: 6).position(x: w - 4, y: midY)
                if flight.phase == .inProgress {
                    Image(systemName: "airplane").font(.system(size: 12)).foregroundStyle(tint)
                        .position(x: max(6, (w - 8) * f), y: midY)
                }
            }
        }
    }
}
