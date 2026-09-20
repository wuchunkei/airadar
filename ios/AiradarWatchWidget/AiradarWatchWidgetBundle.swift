import SwiftUI
import WidgetKit

@main
struct AiradarWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextFlightWidget()
    }
}

struct NextFlightEntry: TimelineEntry {
    let date: Date
    let trip: WatchTrip?
}

/// Reads the same App Group snapshot the watch app itself writes
/// (WatchStore.swift) -- no networking of its own, so it stays as fresh as
/// the last time the phone and watch were able to talk, exactly like the
/// app's own list.
struct NextFlightProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextFlightEntry {
        NextFlightEntry(date: Date(), trip: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextFlightEntry) -> Void) {
        completion(NextFlightEntry(date: Date(), trip: nextTrip()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextFlightEntry>) -> Void) {
        let trip = nextTrip()
        // A handful of entries 15 minutes apart keep the countdown moving
        // without asking WidgetKit to reload more often than its own
        // complication budget really allows.
        let entries = stride(from: 0, to: 8, by: 1).map { i in
            NextFlightEntry(date: Date().addingTimeInterval(Double(i) * 15 * 60), trip: trip)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func nextTrip() -> WatchTrip? {
        WatchSnapshotStore.load().trips.first { $0.arrivalDate > Date() }
    }
}

struct NextFlightWidget: Widget {
    let kind = "NextFlightWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextFlightProvider()) { entry in
            NextFlightWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Flight")
        .description("Countdown to your next flight.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

private struct NextFlightWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextFlightEntry

    var body: some View {
        if let trip = entry.trip {
            switch family {
            case .accessoryCircular: circular(trip)
            default: rectangular(trip)
            }
        } else {
            switch family {
            case .accessoryCircular: Image(systemName: "airplane")
            default: Text("No upcoming flight")
            }
        }
    }

    private func circular(_ trip: WatchTrip) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "airplane").font(.caption2)
            Text(countdownShort(trip)).font(.system(size: 13, weight: .semibold)).minimumScaleFactor(0.7)
        }
        .containerBackground(.clear, for: .widget)
    }

    private func rectangular(_ trip: WatchTrip) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(trip.departure) → \(trip.arrival)").font(.headline)
            Text(countdown(trip)).font(.caption).foregroundStyle(.secondary)
        }
        .containerBackground(.clear, for: .widget)
    }

    private func countdownShort(_ trip: WatchTrip) -> String {
        let target = entry.date < trip.departureDate ? trip.departureDate : trip.arrivalDate
        let minutes = max(0, Int(target.timeIntervalSince(entry.date) / 60))
        return minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    private func countdown(_ trip: WatchTrip) -> String {
        let now = entry.date
        let target = now < trip.departureDate ? trip.departureDate : trip.arrivalDate
        let minutes = max(0, Int(target.timeIntervalSince(now) / 60))
        let label = now < trip.departureDate ? "to boarding" : "to landing"
        let value = minutes >= 60 ? "\(minutes / 60)h\(minutes % 60)m" : "\(minutes)m"
        return "\(value) \(label)"
    }
}
