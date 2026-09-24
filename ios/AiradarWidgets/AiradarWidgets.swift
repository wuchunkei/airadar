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

    /// Share of the way flown by the clock at draw time: 0 before, 1 once down.
    var flownFraction: Double {
        switch stage {
        case .before: return 0
        case .landed: return 1
        case .airborne:
            let total = arrivalDate.timeIntervalSince(departureDate)
            return total > 0 ? min(1, max(0, Date().timeIntervalSince(departureDate) / total)) : 0
        }
    }

    /// The next city along the way, while in the air.
    var nextWaypoint: FlightActivityAttributes.Waypoint? {
        guard stage == .airborne else { return nil }
        let flown = flownFraction
        return waypoints.first { $0.fraction > flown }
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
                        RouteLine(state: s).frame(height: 26)
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
                        RouteLine(state: s).frame(height: 30)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    Endpoint(code: a.arrival, terminal: a.arrivalTerminal, gate: s.arrivalGate, place: a.arrivalCity, clock: s.arrivalClock, alignment: .trailing, large: true)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .foregroundStyle(.white)
    }
}

// MARK: - Pieces

/// Which waypoint codes fit side by side along a line, left to right.
enum WaypointLabels {
    static func fitting(_ fractions: [Double], span: CGFloat) -> Set<Int> {
        var kept: Set<Int> = []
        var lastX = -CGFloat.infinity
        for (i, f) in fractions.enumerated() {
            let x = span * f
            if x - lastX >= 21 { kept.insert(i); lastX = x }
        }
        return kept
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
        // Values alone — "2h 7m", "1128 km", "Belt 106" read for themselves,
        // and the island has no room for a label beside each.
        VStack(alignment: .trailing, spacing: 10) {
            Text(state.durationText)
            Text("\(attributes.distanceKm) km")
            Text(state.baggageClaim.map { "Belt \($0)" } ?? "Belt —")
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .frame(maxHeight: .infinity)
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

/// The same wording as the app's status line: a delay said as "late" (so it
/// can't be read as a duration), and once down, how early or late it landed.
private struct StatusText: View {
    let state: FlightActivityAttributes.ContentState
    var body: some View {
        Text(text).foregroundStyle(color)
    }
    private var text: String {
        if state.statusKind == .bad { return state.statusLabel }
        switch state.stage {
        case .landed:
            guard let d = state.arrivalDelayMinutes else { return "Landed" }
            return d < 0 ? "Landed · \(-d)m early" : d > 0 ? "Landed · \(d)m late" : "Landed · on time"
        case .airborne:
            return "In flight"
        case .before:
            return state.statusLabel + (state.delayMinutes > 0 ? " · \(state.delayMinutes)m late" : "")
        }
    }
    private var color: Color {
        if state.stage == .landed, let d = state.arrivalDelayMinutes { return d > 0 ? .orange : .green }
        switch state.statusKind {
        case .scheduled: return state.delayMinutes > 0 ? .orange : .secondary
        case .live: return .blue
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
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
        if state.stage == .landed {
            // Down: no countdown left to show, just how it came in.
            StatusText(state: state).fontWeight(.semibold)
        } else {
            HStack(spacing: 4) {
                CountdownDigits(state: state).monospacedDigit()
                Text(state.stage == .airborne ? "Landing" : "Boarding")
            }
            .fontWeight(.semibold)
            .foregroundStyle(state.urgency.color)
        }
    }
}

/// Before departure: a solid arrow from left to right. In the air: a system
/// progress bar from take-off to landing, so it fills on its own with the app
/// asleep, and a node at the far end. Landed: the whole line green. Cities
/// along the way sit on it as dots, each with its code beneath (as many as fit);
/// once passed, the dot grows and it and its code turn green.
private struct RouteLine: View {
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        GeometryReader { g in
            // The line near the top, room beneath it for the next city's code.
            let w = g.size.width, midY: CGFloat = 8
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
            let span = w - 12
            let flown = state.flownFraction
            let labelled = WaypointLabels.fitting(state.waypoints.map(\.fraction), span: span)
            ForEach(Array(state.waypoints.enumerated()), id: \.offset) { index, wp in
                let passed = wp.fraction <= flown
                // Ringed in black so a passed dot still reads on the green bar it sits on.
                Circle().fill(passed ? Color.green : Color.white.opacity(0.9))
                    .overlay { if passed { Circle().stroke(.black, lineWidth: 1.5) } }
                    .frame(width: passed ? 9 : 5, height: passed ? 9 : 5)
                    .position(x: span * wp.fraction, y: midY)
                if labelled.contains(index) {
                    let isNext = wp == state.nextWaypoint
                    Text(wp.code).font(.system(size: 9, weight: isNext ? .bold : .semibold).monospaced())
                        .foregroundStyle(passed ? Color.green : Color.white.opacity(isNext ? 1 : 0.6)).fixedSize()
                        .position(x: min(max(12, span * wp.fraction), w - 12), y: midY + 12)
                }
            }
        }
    }
}
