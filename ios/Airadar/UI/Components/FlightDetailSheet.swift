import SwiftUI

/// The bottom sheet for one flight: a map thumbnail, airline and status, the big
/// airport codes, times (a delay shows the original struck through), the facts,
/// and whatever actions the caller adds.
struct FlightDetailSheet<Actions: View>: View {
    let flight: Flight
    var forceSystemZone = false
    var trackStatus: TrackStatus? = nil
    var onLoadTrack: (() -> Void)? = nil
    let onDismiss: () -> Void
    var primaryAction: (label: String, action: () -> Void)? = nil
    /// Under the primary one, quieter — "Incorrect" beneath "Correct".
    var secondaryAction: (label: String, action: () -> Void)? = nil
    @ViewBuilder var extraActions: () -> Actions

    /// Measured content height: the sheet opens just tall enough, not full screen.
    @State private var contentHeight: CGFloat = 0
    @State private var fullMap = false
    @State private var detent: PresentationDetent = .medium
    @State private var fittedHeight: CGFloat = 0
    @State private var trackRefreshed: Date?
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TileMapView(routes: routes, tracks: tracks, interactive: false, cityLabels: true)
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.bold))
                            .padding(6).background(.thinMaterial, in: .circle).padding(8)
                    }
                    .contentShape(.rect)
                    .onTapGesture { fullMap = true }
                    // Presented from inside the content: a presentation modifier on the sheet's
                    // root would swallow the detents declared beneath it.
                    .fullScreenCover(isPresented: $fullMap) { fullMapView }

                header
                codes
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
        // Measured: settle on the fitted height rather than leaving the sheet at whatever it
        // opened at. Small re-measurements (a label wrapping) are ignored so it does not twitch;
        // the selection is asserted again a beat later, after the detent set has taken it in.
        .onChange(of: contentHeight + footerHeight, initial: true) { _, total in
            guard total > 0, abs(total - fittedHeight) > 4 else { return }
            fittedHeight = total
            if let fitted = fittedDetent(total) {
                detent = fitted
                Task { @MainActor in detent = fitted }
            }
        }
        // In the air: the path flown so far is fetched quietly, so the plane sits where it really is.
        .task(id: flight.id) {
            if flight.phase == .inProgress, flight.trackFlownOn == nil, flight.callsign != nil { onLoadTrack?() }
        }
        // Outermost, so nothing between them and the sheet can swallow them.
        .presentationDetents(detents, selection: $detent)
        .presentationDragIndicator(.visible)
    }

    /// The whole map. While the flight is in the air the track is asked for again every
    /// minute and a half; with nothing new from the network the line drawn last stays.
    private var fullMapView: some View {
            NavigationStack {
                TileMapView(routes: routes, tracks: tracks, interactive: true, cityLabels: true)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("\(flight.flightNumber) · \(flight.departure) → \(flight.arrival)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { fullMap = false } } }
                    .safeAreaInset(edge: .bottom) {
                        if flight.phase == .inProgress {
                            HStack(spacing: 8) {
                                if trackStatus == .loading { ProgressView().controlSize(.small) }
                                Text(trackCaption).font(.caption).foregroundStyle(trackStatus?.isFailure == true ? .red : .secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule).padding(.bottom, 12)
                        }
                    }
                    .onChange(of: trackStatus) { _, s in if s == .loaded { trackRefreshed = Date() } }
                    .task {
                        guard flight.phase == .inProgress, flight.callsign != nil else { return }
                        onLoadTrack?()
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(90))
                            onLoadTrack?()
                        }
                    }
            }
    }

    private var trackCaption: String {
        switch trackStatus {
        case .loading: return "Fetching the track"
        case .failed(let why): return "Track not available: \(why)"
        default:
            if let t = trackRefreshed {
                let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
                return "Track updated \(f.string(from: t)) · every 90 s"
            }
            return flight.track == nil ? "Estimated from the timetable" : "Track as last received"
        }
    }

    private var screenHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.bounds.height ?? 844
    }

    /// Just tall enough for the content; only content that does not fit on one
    /// screen can be pulled up to full height.
    /// Exactly as tall as the content, so the whole flight is on one page; content taller
    /// than a sheet can be gets the tallest sheet there is and scrolls for the rest.
    private var detents: Set<PresentationDetent> {
        guard fittedHeight > 0 else { return [.medium] }
        return fittedHeight < screenHeight * 0.92 ? [.height(fittedHeight)] : [.large]
    }

    private func fittedDetent(_ total: CGFloat) -> PresentationDetent? {
        guard total > 0 else { return nil }
        return total < screenHeight * 0.92 ? .height(total) : .large
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
                Text(flight.status.label).fontWeight(.semibold).foregroundStyle(flight.status.color)
            }
        }
    }

    private var codes: some View {
        HStack(spacing: 12) {
            BigCode(code: flight.departure, terminal: flight.departureTerminal, city: flight.departureAirport?.cityCountry, trailing: false)
            // The way between: an arrow before departure, the plane along a dashed line in the air, done after.
            FlightProgressLine(flight: flight).frame(maxWidth: .infinity).frame(height: 18)
            BigCode(code: flight.arrival, terminal: flight.arrivalTerminal, city: flight.arrivalAirport?.cityCountry, trailing: true)
        }
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
            if let a = flight.aircraft { DetailRow(label: "Aircraft", value: a) }
            // Belt numbers appear close to landing; the row is always there.
            DetailRow(label: "Baggage claim", value: flight.baggageClaim ?? "–")
            if let p = flight.pnr { DetailRow(label: "Booking reference", value: p) }
            if let s = flight.sharedBy { DetailRow(label: "Shared by", value: s.person.givenName, secondary: s.status.label) }
        }
    }

    private var routes: [MapRoute] {
        guard flight.track == nil, let a = flight.departureAirport, let b = flight.arrivalAirport else { return [] }
        let progress: Double? = flight.phase == .inProgress ? flight.fractionFlown : nil
        return [MapRoute(from: a, to: b, rank: 0, isReturn: false, progress: progress)]
    }

    private var tracks: [MapTrack] {
        guard let t = flight.track, let a = flight.departureAirport, let b = flight.arrivalAirport else { return [] }
        return [MapTrack(from: a, to: b, points: t, live: flight.phase == .inProgress)]
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
    let code: String, terminal: String?, city: String?, trailing: Bool
    var body: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(city ?? "").font(.caption).foregroundStyle(.secondary)
            Text(code).font(.system(size: 40, weight: .bold))
            if let terminal { Text("Terminal \(terminal)").font(.caption).foregroundStyle(.secondary) }
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
