import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AiradarWidgets: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
    }
}

// MARK: - Where the flight is

/// Read off the clock at render time, so the same content draws the right stage.
private enum Stage { case before, airborne, landed }

private extension FlightActivityAttributes.ContentState {
    var stage: Stage {
        let now = Date()
        if landed || now >= arrivalDate { return .landed }
        return now < departureDate ? .before : .airborne
    }

    /// What the plane should be over right now, while it's in the air.
    var passingOver: String? {
        guard stage == .airborne else { return nil }
        let now = Date()
        return waypoints.last { $0.at <= now }?.name
    }

    /// Hours to departure (negative once gone).
    var hoursToGo: Double { departureDate.timeIntervalSinceNow / 3600 }

    /// The countdown's colour: grey a day out, white within 12 h, then yellow, orange, red by the hour; green in the air.
    var urgency: Urgency {
        switch stage {
        case .airborne: return .airborne
        case .landed: return .done
        case .before:
            let h = hoursToGo
            if h >= 12 { return .far }
            if h >= 3 { return .near }
            if h >= 2 { return .hours2 }
            if h >= 1 { return .hour1 }
            return .last
        }
    }

    var durationText: String {
        let minutes = Int(arrivalDate.timeIntervalSince(departureDate) / 60)
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private enum Urgency {
    case far, near, hours2, hour1, last, airborne, done

    var color: Color {
        switch self {
        case .far: .secondary
        case .near: .white
        case .hours2: .yellow
        case .hour1: .orange
        case .last: .red
        case .airborne, .done: .green
        }
    }
}

// MARK: - The widget

struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state, a = context.attributes
            return DynamicIsland {
                // The expanded island narrows right where the sensor housing
                // sits, at the very top of the leading/trailing regions -- a
                // code+terminal row starting flush against that edge (as
                // "ICN T2" did) reads as cut off by the housing itself. A
                // little inward padding, matching the same fix RouteLine
                // already needed at the bottom for the same reason, keeps it
                // clear without shrinking anything.
                DynamicIslandExpandedRegion(.leading) {
                    Group {
                        if s.stage == .landed {
                            Endpoint(code: a.arrival, terminal: a.arrivalTerminal, gate: s.arrivalGate, place: a.arrivalCity, clock: s.arrivalClock, alignment: .leading)
                        } else {
                            Endpoint(code: a.departure, terminal: a.departureTerminal, gate: s.departureGate, place: a.departureCity, clock: s.departureClock, alignment: .leading)
                        }
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if s.stage == .landed {
                            Facts(state: s, attributes: a)
                        } else {
                            Endpoint(code: a.arrival, terminal: a.arrivalTerminal, gate: s.arrivalGate, place: a.arrivalCity, clock: s.arrivalClock, alignment: .trailing)
                        }
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 6) {
                        AirlineMark(logo: a.logo, size: 20)
                        Text(a.flightNumber).font(.subheadline.monospaced().weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Countdown(state: s).font(.caption)
                        RouteLine(state: s).frame(height: 16)
                        if let over = s.passingOver { PassingOver(name: over).font(.caption2) }
                    }
                    .padding(.top, 2)
                    // The bottom region spans the island's full width, so its
                    // own rounded corners are the widest ones on the whole
                    // shape -- the route line's end node and plane, drawn
                    // right at the edge, read as clipped by that curve the
                    // same way the top rows did. RouteLine sizes itself off
                    // the space it's actually given, so this alone pulls
                    // everything in without touching its own math.
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                if s.stage == .landed {
                    Text(a.arrival).font(.caption.weight(.bold))
                } else {
                    AirlineMark(logo: a.logo, size: 20)
                }
            } compactTrailing: {
                if s.stage == .landed {
                    Text(s.baggageClaim.map { "Belt \($0)" } ?? "Landed").font(.caption.weight(.semibold)).foregroundStyle(.green)
                } else {
                    CountdownDigits(state: s).font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(s.urgency.color)
                        .multilineTextAlignment(.center).minimumScaleFactor(0.8).frame(width: 56, alignment: .center)
                }
            } minimal: {
                AirlineMark(logo: a.logo, size: 18)
            }
            .keylineTint(s.urgency.color)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let context: ActivityViewContext<FlightActivityAttributes>

    var body: some View {
        let s = context.state, a = context.attributes
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AirlineMark(logo: a.logo, size: 26)
                Text(a.flightNumber).font(.headline.monospaced())
                Text(a.airlineName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                StatusText(state: s).font(.caption.weight(.semibold))
            }
            if s.stage == .landed {
                HStack(alignment: .center) {
                    Endpoint(code: a.arrival, terminal: a.arrivalTerminal, gate: s.arrivalGate, place: a.arrivalCity, clock: s.arrivalClock, alignment: .leading, large: true)
                    Spacer()
                    Facts(state: s, attributes: a)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Endpoint(code: a.departure, terminal: a.departureTerminal, gate: s.departureGate, place: a.departureCity, clock: s.departureClock, alignment: .leading, large: true)
                    // The middle: countdown above, the route line below.
                    VStack(spacing: 10) {
                        Countdown(state: s).font(.subheadline)
                        RouteLine(state: s).frame(height: 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    Endpoint(code: a.arrival, terminal: a.arrivalTerminal, gate: s.arrivalGate, place: a.arrivalCity, clock: s.arrivalClock, alignment: .trailing, large: true)
                }
                if let over = s.passingOver { PassingOver(name: over).font(.caption) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .foregroundStyle(.white)
    }
}

// MARK: - Pieces

/// "Over Johor, Malaysia": where the route should have got to by now.
private struct PassingOver: View {
    let name: String
    var body: some View {
        Label("Over \(name)", systemImage: "location.fill")
            .foregroundStyle(.secondary).lineLimit(1).labelStyle(.titleAndIcon)
    }
}

/// Code and terminal on one line (same size, the terminal quieter), the city and
/// country beneath, the local time beneath that.
private struct Endpoint: View {
    let code: String
    let terminal: String?
    /// Shown in place of the city on the island (no room for both), beside it on the lock screen.
    var gate: String? = nil
    let place: String
    let clock: String
    let alignment: HorizontalAlignment
    /// The lock screen has room for bigger type than the island.
    var large = false

    var body: some View {
        VStack(alignment: alignment, spacing: large ? 3 : 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(code).font(large ? .title2.bold() : .title3.bold())
                if let terminal { Text("T\(terminal)").font(large ? .title2.bold() : .title3.bold()).foregroundStyle(.secondary) }
            }
            if let gate {
                Text(large ? "\(place) · Gate \(gate)" : "Gate \(gate)")
                    .font((large ? Font.caption : Font.caption2).weight(.semibold)).lineLimit(1)
            } else {
                Text(place).font(large ? .caption : .caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(clock).font((large ? Font.body : Font.subheadline).monospacedDigit().weight(.semibold))
        }
    }
}

/// After landing: how long it took, how far it went, which belt.
private struct Facts: View {
    let state: FlightActivityAttributes.ContentState
    let attributes: FlightActivityAttributes
    var body: some View {
        // Three rows spread across the same height the endpoint block beside
        // them takes up, at a size that actually matches it -- cramped into
        // a tight, tiny-type corner (the original .caption/2pt-spacing look)
        // read as an afterthought next to a large airport code.
        VStack(alignment: .trailing, spacing: 10) {
            fact("Duration", state.durationText)
            fact("Distance", "\(attributes.distanceKm) km")
            fact("Baggage", state.baggageClaim.map { "Belt \($0)" } ?? "—")
        }
        .font(.subheadline)
        .frame(maxHeight: .infinity)
    }
    private func fact(_ name: String, _ value: String) -> some View {
        HStack(spacing: 6) { Text(name).foregroundStyle(.secondary); Text(value).fontWeight(.semibold) }
    }
}

/// The airline's mark, or a plane when none was found.
private struct AirlineMark: View {
    let logo: Data?
    let size: CGFloat
    var body: some View {
        if let logo, let ui = UIImage(data: logo) {
            Image(uiImage: ui).resizable().scaledToFit().frame(width: size, height: size).clipShape(.rect(cornerRadius: size * 0.22))
        } else {
            Image(systemName: "airplane").font(.system(size: size * 0.8)).foregroundStyle(.blue).frame(width: size, height: size)
        }
    }
}

private struct StatusText: View {
    let state: FlightActivityAttributes.ContentState
    var body: some View {
        Text(state.statusLabel + (state.delayMinutes > 0 ? " +\(state.delayMinutes) min" : ""))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch state.statusKind {
        case .scheduled: .secondary
        case .live: .blue
        case .good: .green
        case .warn: .orange
        case .bad: .red
        }
    }
}

/// A system timer, so it keeps ticking with the app asleep: to departure before,
/// to landing in the air.
private struct CountdownDigits: View {
    let state: FlightActivityAttributes.ContentState
    var body: some View {
        switch state.stage {
        case .landed: Text("Landed")
        case .before: Text(timerInterval: Date.now...max(Date.now, state.departureDate), countsDown: true)
        case .airborne: Text(timerInterval: Date.now...max(Date.now, state.arrivalDate), countsDown: true)
        }
    }
}

/// The digits with their word, coloured by how close it is — no border, just the colour.
private struct Countdown: View {
    let state: FlightActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 4) {
            CountdownDigits(state: state).monospacedDigit()
            Text(state.stage == .airborne ? "Landing" : "Boarding")
        }
        .fontWeight(.semibold)
        .foregroundStyle(state.urgency.color)
    }
}

/// Before departure: a solid arrow from left to right. In the air: a system
/// progress bar from take-off to landing, so it fills on its own with the app
/// asleep, and a node at the far end. Landed: the whole line green.
private struct RouteLine: View {
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, midY = g.size.height / 2
            switch state.stage {
            case .before:
                // Kept well clear of the island's own rounded corner — flush against
                // the true edge, the arrowhead crowded the curve and looked cut off.
                Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: w - 14, y: midY)) }
                    .stroke(.white.opacity(0.9), lineWidth: 1.5)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                    .position(x: w - 8, y: midY)
            case .airborne:
                ProgressView(timerInterval: state.departureDate...max(state.departureDate, state.arrivalDate), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(.green)
                .frame(width: w - 10)
                .position(x: (w - 10) / 2, y: midY)
                Circle().fill(.white.opacity(0.9)).frame(width: 6, height: 6).position(x: w - 4, y: midY)
            case .landed:
                Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: w - 8, y: midY)) }
                    .stroke(.green, lineWidth: 2)
                Circle().fill(.white.opacity(0.9)).frame(width: 6, height: 6).position(x: w - 4, y: midY)
                Image(systemName: "airplane").font(.system(size: 11)).foregroundStyle(.green)
                    .position(x: w - 14, y: midY)
            }
        }
    }
}
