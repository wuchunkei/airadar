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
                    Endpoint(code: context.attributes.departure, terminal: context.attributes.departureTerminal,
                             clock: context.state.departureClock, detail: gateLine(context.state.departureGate), alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Endpoint(code: context.attributes.arrival, terminal: context.attributes.arrivalTerminal,
                             clock: context.state.arrivalClock, detail: arrivalLine(context), alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 6) {
                        AirlineMark(logo: context.attributes.logo, size: 22)
                        VStack(spacing: 1) {
                            Text(context.attributes.flightNumber).font(.headline.monospaced())
                            Text(context.attributes.airlineName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
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
                // The airline's mark alone; the words are in the expanded view.
                AirlineMark(logo: context.attributes.logo, size: 20)
            } compactTrailing: {
                // A live timer reserves room for its widest value; centre the digits in it.
                Countdown(state: context.state).font(.caption.monospacedDigit())
                    .multilineTextAlignment(.center).frame(width: 52, alignment: .center)
            } minimal: {
                AirlineMark(logo: context.attributes.logo, size: 18)
            }
            .keylineTint(.blue)
        }
    }

    private func gateLine(_ gate: String?) -> String? { gate.map { "Gate \($0)" } }

    private func arrivalLine(_ context: ActivityViewContext<FlightActivityAttributes>) -> String? {
        if let belt = context.state.baggageClaim { return "Belt \(belt)" }
        return gateLine(context.state.arrivalGate)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<FlightActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AirlineMark(logo: context.attributes.logo, size: 22)
                Text(context.attributes.flightNumber).font(.headline.monospaced())
                Text(context.attributes.airlineName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                StatusText(state: context.state).font(.caption.weight(.semibold))
            }
            // The countdown sits on the true centre line, whatever the two ends measure.
            HStack(alignment: .top) {
                Endpoint(code: context.attributes.departure, terminal: context.attributes.departureTerminal,
                         clock: context.state.departureClock, detail: context.attributes.departureCity, alignment: .leading)
                Spacer(minLength: 60)
                Endpoint(code: context.attributes.arrival, terminal: context.attributes.arrivalTerminal,
                         clock: context.state.arrivalClock, detail: context.attributes.arrivalCity, alignment: .trailing)
            }
            .overlay(alignment: .top) {
                Countdown(state: context.state).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.top, 8)
            }
            ProgressLine(state: context.state)
        }
        .padding(14)
        .foregroundStyle(.white)
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

private struct Endpoint: View {
    let code: String
    let terminal: String?
    let clock: String
    let detail: String?
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(code).font(.title3.bold())
                if let terminal { Text("T\(terminal)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
            }
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
