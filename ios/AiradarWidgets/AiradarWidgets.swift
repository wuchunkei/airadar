import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AiradarWidgets: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
    }
}

/// The flight on the lock screen and in the Dynamic Island: where it is between
/// the two airports, when it leaves or lands, gate and belt as they are known.
struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Endpoint(code: context.attributes.departure, clock: context.state.departureClock,
                             detail: gateLine(context.attributes.departureTerminal, context.state.departureGate), alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Endpoint(code: context.attributes.arrival, clock: context.state.arrivalClock,
                             detail: arrivalLine(context), alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.flightNumber).font(.headline.monospaced())
                        Text(context.attributes.airlineName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressLine(state: context.state)
                        HStack {
                            StatusText(state: context.state)
                            Spacer()
                            Countdown(state: context.state)
                        }
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: "airplane").foregroundStyle(.blue)
                    Text(context.attributes.flightNumber).font(.caption.monospaced().weight(.semibold))
                }
            } compactTrailing: {
                Countdown(state: context.state).font(.caption.monospacedDigit()).frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "airplane").foregroundStyle(.blue)
            }
            .keylineTint(.blue)
        }
    }

    private func gateLine(_ terminal: String?, _ gate: String?) -> String? {
        var parts: [String] = []
        if let terminal { parts.append("T\(terminal)") }
        if let gate { parts.append("Gate \(gate)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func arrivalLine(_ context: ActivityViewContext<FlightActivityAttributes>) -> String? {
        if let belt = context.state.baggageClaim { return "Belt \(belt)" }
        return gateLine(context.attributes.arrivalTerminal, context.state.arrivalGate)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<FlightActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "airplane")
                Text(context.attributes.flightNumber).font(.headline.monospaced())
                Text(context.attributes.airlineName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                StatusText(state: context.state).font(.caption.weight(.semibold))
            }
            HStack(alignment: .top) {
                Endpoint(code: context.attributes.departure, clock: context.state.departureClock,
                         detail: context.attributes.departureCity, alignment: .leading)
                Spacer()
                Countdown(state: context.state).font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.top, 6)
                Spacer()
                Endpoint(code: context.attributes.arrival, clock: context.state.arrivalClock,
                         detail: context.attributes.arrivalCity, alignment: .trailing)
            }
            ProgressLine(state: context.state)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

private struct Endpoint: View {
    let code: String
    let clock: String
    let detail: String?
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(code).font(.title3.bold())
            Text(clock).font(.subheadline.monospacedDigit())
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
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

/// Before departure: time until it leaves. In the air: time until it lands. After: "Landed".
private struct Countdown: View {
    let state: FlightActivityAttributes.ContentState
    var body: some View {
        let now = Date()
        if now < state.departureDate {
            Text(timerInterval: now...state.departureDate, countsDown: true, showsHours: true)
        } else if now < state.arrivalDate {
            Text(timerInterval: now...state.arrivalDate, countsDown: true, showsHours: true)
        } else {
            Text("Landed")
        }
    }
}

/// The plane's way along the route, live while airborne.
private struct ProgressLine: View {
    let state: FlightActivityAttributes.ContentState
    var body: some View {
        let now = Date()
        if now < state.departureDate {
            ProgressView(value: 0).tint(.secondary)
        } else if now < state.arrivalDate {
            ProgressView(timerInterval: state.departureDate...state.arrivalDate, countsDown: false,
                         label: { EmptyView() }, currentValueLabel: { EmptyView() })
                .tint(.blue)
        } else {
            ProgressView(value: 1).tint(.green)
        }
    }
}
