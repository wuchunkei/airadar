import SwiftUI

/// The bottom sheet for one flight: a map thumbnail, airline and status, the big
/// airport codes, times (a delay shows the original struck through), the facts,
/// and whatever actions the caller adds.
struct FlightDetailSheet<Actions: View>: View {
    @EnvironmentObject private var store: FlightStore
    let flight: Flight
    var forceSystemZone = false
    var trackStatus: TrackStatus? = nil
    var onLoadTrack: (() -> Void)? = nil
    /// The aircraft's real position while it flies, asked for every minute the sheet is open.
    @State private var live: LivePosition?
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
                TileMapView(routes: routes, tracks: [], interactive: false, cityLabels: true, livePlane: live)
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 16))

                header
                codes
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
        // In the air: where the aircraft really is, from ADS-B, refreshed every minute.
        .task(id: "\(flight.id)|\(callsign ?? "")") {
            guard let callsign else { return }
            while !Task.isCancelled, flight.phase == .inProgress {
                if let p = await LivePositionClient.shared.position(callsign: callsign) { live = p }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // OpenSky gets the first shot at a real track — free, whatever the
        // phase — quietly, the way it always has.
        .task(id: "\(flight.id)|\(callsign ?? "")") {
            if flight.trackFlownOn == nil, callsign != nil { onLoadTrack?() }
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
            BigCode(code: flight.departure, terminal: flight.departureTerminal ?? enrichedFlight?.departureTerminal,
                    gate: flight.departureGate ?? enrichedFlight?.departureGate, city: flight.departureAirport?.cityCountry, trailing: false)
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

    private var routes: [MapRoute] {
        guard let a = flight.departureAirport, let b = flight.arrivalAirport else { return [] }
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
    var body: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(city ?? "").font(.caption).foregroundStyle(.secondary)
            Text(code).font(.system(size: 40, weight: .bold))
            if terminal != nil || gate != nil {
                Text([terminal.map { "Terminal \(normalizeTerminal($0))" }, gate.map { "Gate \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                let green = Color(red: 0.20, green: 0.70, blue: 0.30)
                Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: w - 8, y: midY)) }
                    .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: (w - 8) * f, y: midY)) }
                    .stroke(green, lineWidth: 2)
                Circle().fill(Color.secondary).frame(width: 6, height: 6).position(x: w - 4, y: midY)
                if flight.phase == .inProgress {
                    Image(systemName: "airplane").font(.system(size: 12)).foregroundStyle(green)
                        .position(x: max(6, (w - 8) * f), y: midY)
                }
            }
        }
    }
}
