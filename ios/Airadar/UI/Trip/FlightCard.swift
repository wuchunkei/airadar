import SwiftUI

/// One trip: airline / number, departure row, arrival row, status + shares + usual
/// duration. A friend's trip wears their colour; a pending one is dashed.
struct FlightCard: View {
    let flight: Flight
    let forceSystemZone: Bool
    var dimmed = false
    let onTap: () -> Void

    @State private var expandedShares = false
    @State private var routeValid = false
    @State private var showMapChooser = false
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var store: FlightStore

    private var shared: TripShare? { flight.sharedBy }
    /// Once taken together it is my own trip again, and only the name block remains.
    private var ground: Color? { shared.flatMap { $0.status == .together ? nil : $0.person.tint } }
    private var dashed: Bool { flight.isPending || shared?.status == .pending }
    private var ink: Color { ground?.onColor ?? .primary }
    private var inkMuted: Color { ground != nil ? ink.opacity(0.72) : .secondary }
    private var rejected: Bool { flight.feedStatus == .rejected }
    /// The community's 7-day review window ran out without reaching 70%
    /// approval — not the same as rejected: no one decided this was fake,
    /// it just ran out of time. Milder colour, same "still yours" freedom.
    private var expired: Bool { flight.feedStatus == .expired }
    /// Another of the traveller's own flights overlapping this one in time —
    /// physically impossible, so a strong sign this one (or the other) was
    /// actually imported from someone else's ticket.
    private var conflict: Flight? { FlightConflicts.overlapping(flight, in: store.flights) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                if PassengerName.looksLikeSomeoneElse(flight, mine: auth.user?.passengerName) {
                    Label("This may not be your trip — the ticket names someone else", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color(red: 0.96, green: 0.65, blue: 0.14))
                }
                if let conflict {
                    Label("Overlaps with \(conflict.flightNumber) — you can't be on two flights at once; this may not be your trip",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
                if rejected {
                    Label("Blocked — this flight couldn't be confirmed", systemImage: "xmark.octagon.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                } else if expired {
                    Label("Unverified — review expired", systemImage: "clock.badge.exclamationmark")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                if dashed && shared == nil {
                    Text("Imported · needs review").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
                HStack {
                    Text(flight.airlineName.isEmpty ? "—" : flight.airlineName).font(.subheadline.weight(.medium)).foregroundStyle(ink)
                    Spacer()
                    Text(flight.flightNumber).font(.subheadline.bold()).foregroundStyle(ground == nil ? Color.accentColor : ink)
                }
                AirportRow(city: flight.departureAirport.map { "\($0.city), \($0.countryCode)" }, code: flight.departure,
                           terminal: flight.departureTerminal, time: flight.shownTime(arrival: false, forceSystemZone: forceSystemZone),
                           ink: ink, muted: inkMuted, highlighted: routeValid,
                           onTap: routeValid ? { showMapChooser = true } : nil)
                AirportRow(city: flight.arrivalAirport.map { "\($0.city), \($0.countryCode)" }, code: flight.arrival,
                           terminal: flight.arrivalTerminal, time: flight.shownTime(arrival: true, forceSystemZone: forceSystemZone),
                           ink: ink, muted: inkMuted)
                HStack(spacing: 8) {
                    StatusChip(flight: flight)
                    if flight.isManual { NameBlock(name: "Manual", color: Color(red: 0.96, green: 0.65, blue: 0.14), dashed: false) }
                    if rejected { NameBlock(name: "Blocked", color: .red, dashed: false) }
                    else if expired { NameBlock(name: "Expired", color: .orange, dashed: false) }
                    if let via = flight.importedVia {
                        NameBlock(name: via == "gmail" ? "Email" : "Calendar", color: .secondary, dashed: false)
                    }
                    ShareBlocks(flight: flight, ink: ink, expanded: $expandedShares)
                    Spacer(minLength: 4)
                    Text("Usually \(formatDuration(flight.typicalDurationMinutes ?? flight.durationMinutes))")
                        .font(.caption).foregroundStyle(inkMuted)
                }
                if expandedShares, flight.shares.count > 2 { ShareList(flight: flight, ink: ink) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground, in: .rect(cornerRadius: 20))
            .overlay {
                // Rejected wins over every other border style — a blocked
                // flight needs to read as blocked at a glance, dashed or not.
                if rejected {
                    RoundedRectangle(cornerRadius: 20).strokeBorder(Color.red, lineWidth: 1.5)
                } else if expired {
                    RoundedRectangle(cornerRadius: 20).strokeBorder(Color.orange, lineWidth: 1.5)
                } else if dashed {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                        .foregroundStyle(ground ?? Color.accentColor)
                } else {
                    // A hairline so the card still separates from the page when the fill is faint.
                    RoundedRectangle(cornerRadius: 20).strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        // Same last-24h-before-departure window as the detail sheet's own
        // check -- any earlier and "can I drive there right now" isn't the
        // traveller's question yet.
        .task(id: flight.id) {
            routeValid = false
            guard flight.phase == .upcoming, let airport = flight.departureAirport,
                  let departs = flight.departureInstant,
                  departs.timeIntervalSinceNow > 0, departs.timeIntervalSinceNow < 86_400 else { return }
            routeValid = await RouteValidity.hasDrivableRoute(to: airport)
        }
        .sheet(isPresented: $showMapChooser) {
            if let airport = flight.departureAirport { MapChooserSheet(airport: airport) }
        }
    }

    private var cardBackground: some ShapeStyle {
        if let ground {
            // Waiting on my answer: the friend's colour only as an outline and a tint.
            return AnyShapeStyle(dashed ? ground.opacity(0.18) : ground)
        }
        // secondarySystemBackground reads on the page's plain background in both themes;
        // the grouped variant is white-on-white in light mode.
        return AnyShapeStyle(dimmed ? Color(.secondarySystemBackground).opacity(0.55) : Color(.secondarySystemBackground))
    }
}

struct AirportRow: View {
    let city: String?
    let code: String
    let terminal: String?
    let time: ShownTime
    let ink: Color
    let muted: Color
    var highlighted: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    let codeText = Text(code).font(.title3.bold())
                        .foregroundStyle(highlighted ? Color(red: 0.043, green: 0.435, blue: 0.831) : ink)
                    if let onTap {
                        Button(action: onTap) { codeText }.buttonStyle(.plain)
                    } else {
                        codeText
                    }
                    if let terminal { Text("T\(normalizeTerminal(terminal))").font(.title3.bold()).foregroundStyle(ink) }
                }
                Text(city ?? "").font(.caption).foregroundStyle(muted)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let original = time.original {
                    Text(original).font(.subheadline).strikethrough().foregroundStyle(muted)
                }
                Text(time.clock).font(.title3.bold())
                    .foregroundStyle(time.original == nil ? ink : time.early ? FlightStatus.onTime.color : FlightStatus.delayed.color)
                Text(time.zone).font(.caption).foregroundStyle(muted)
            }
        }
    }
}

struct StatusChip: View {
    let flight: Flight
    var body: some View {
        // Redrawn every minute so the time in the air keeps counting up.
        TimelineView(.everyMinute) { context in
            Text(flight.statusLine(at: context.date))
                .font(.caption.weight(.semibold)).foregroundStyle(flight.statusColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(flight.statusColor.opacity(0.14), in: .rect(cornerRadius: 6))
        }
    }
}

/// Next to the status: a friend's name on a trip they shared, or a block per friend
/// I shared mine with, coloured by their answer. Past two, the rest fold behind a chevron.
struct ShareBlocks: View {
    let flight: Flight
    let ink: Color
    @Binding var expanded: Bool

    var body: some View {
        let outgoing = flight.shares.sortedForDisplay()
        HStack(spacing: 6) {
            if let s = flight.sharedBy {
                NameBlock(name: s.person.givenName, color: s.status == .together ? s.person.tint : ink, dashed: s.status == .pending)
            } else if outgoing.count <= 2 {
                ForEach(outgoing) { NameBlock(name: $0.person.givenName, color: $0.status.blockColor, dashed: false) }
            } else if let first = outgoing.first {
                NameBlock(name: first.person.givenName, color: first.status.blockColor, dashed: false)
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 2) {
                        Text("+\(outgoing.count - 1)").font(.caption.weight(.semibold))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(ink.opacity(0.10), in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The folded list: every friend, name in their colour, answer on the right.
struct ShareList: View {
    let flight: Flight
    let ink: Color
    var body: some View {
        VStack(spacing: 8) {
            Divider().overlay(ink.opacity(0.12))
            ForEach(flight.shares.sortedForDisplay()) { s in
                HStack {
                    Text(s.person.givenName).font(.subheadline.weight(.medium)).foregroundStyle(s.person.tint)
                    Spacer()
                    Text(s.status.label).font(.caption.weight(.semibold)).foregroundStyle(s.status.blockColor)
                }
            }
        }
    }
}

struct NameBlock: View {
    let name: String
    let color: Color
    let dashed: Bool
    var body: some View {
        Text(name).font(.caption.weight(.semibold)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background { if !dashed { RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.16)) } }
            .overlay { if dashed { RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])).foregroundStyle(color) } }
    }
}

extension Array where Element == TripShare {
    /// Order for a card's share blocks: the state that matters most first, then by name.
    func sortedForDisplay() -> [TripShare] {
        sorted { a, b in
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            return a.person.givenName.lowercased() < b.person.givenName.lowercased()
        }
    }
}
