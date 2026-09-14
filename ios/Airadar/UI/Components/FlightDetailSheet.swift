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
    @ViewBuilder var extraActions: () -> Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TileMapView(routes: routes, tracks: tracks, interactive: false)
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 16))

                // Only a leg that has flown (or is flying) has a track to fetch.
                if let onLoadTrack, flight.callsign != nil, flight.phase != .upcoming {
                    TrackLoader(phase: flight.phase, flownOn: flight.trackFlownOn, status: trackStatus, onLoad: onLoadTrack)
                }

                header
                codes
                facts

                if let primary = primaryAction {
                    Button(action: primary.action) {
                        Text(primary.label).fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                }
                extraActions()
            }
            .padding(20)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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
        HStack {
            BigCode(code: flight.departure, terminal: flight.departureTerminal, city: flight.departureAirport?.city, trailing: false)
            Spacer()
            Image(systemName: "airplane").foregroundStyle(.secondary)
            Spacer()
            BigCode(code: flight.arrival, terminal: flight.arrivalTerminal, city: flight.arrivalAirport?.city, trailing: true)
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
        return [MapRoute(from: a, to: b, weight: 1)]
    }

    private var tracks: [MapTrack] {
        guard let t = flight.track, let a = flight.departureAirport, let b = flight.arrivalAirport else { return [] }
        return [MapTrack(from: a, to: b, points: t)]
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
         onDismiss: @escaping () -> Void, primaryAction: (label: String, action: () -> Void)? = nil) {
        self.init(flight: flight, forceSystemZone: forceSystemZone, trackStatus: trackStatus, onLoadTrack: onLoadTrack,
                  onDismiss: onDismiss, primaryAction: primaryAction, extraActions: { EmptyView() })
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

private struct TrackLoader: View {
    let phase: FlightPhase
    let flownOn: String?
    let status: TrackStatus?
    let onLoad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(text).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if status == .loading { ProgressView().controlSize(.small) }
                else { Button(flownOn == nil ? "Load flown track" : "Reload", action: onLoad).font(.caption) }
            }
            if case .failed(let reason) = status { Text(reason).font(.caption).foregroundStyle(.red) }
        }
    }

    private var text: String {
        if status == .loading { return "Fetching ADS-B track" }
        if flownOn == nil { return "Route shown as a great circle" }
        return phase == .inProgress ? "Showing the path flown so far" : "Showing the path actually flown"
    }
}
