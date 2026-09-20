import SwiftUI

struct ContentView: View {
    @ObservedObject private var store = WatchStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.snapshot.trips.isEmpty {
                    emptyState
                } else {
                    List {
                        NowCard(trip: store.snapshot.trips[0])
                            .listRowBackground(Color.clear)
                        if store.snapshot.trips.count > 1 {
                            Section("Later") {
                                ForEach(store.snapshot.trips.dropFirst()) { trip in
                                    TripRow(trip: trip)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Airadar")
        }
        .onAppear { store.activate() }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "airplane").font(.title2).foregroundStyle(.secondary)
            Text("No trips yet").font(.headline)
            Text("Open Airadar on your iPhone").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// The next trip, full width: route, countdown, status.
private struct NowCard: View {
    let trip: WatchTrip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trip.flightNumber).font(.headline.monospaced())
                Spacer()
                Text(trip.statusLabel + (trip.delayMinutes > 0 ? " +\(trip.delayMinutes)m" : ""))
                    .font(.caption2.weight(.semibold)).foregroundStyle(trip.statusKind.color)
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(trip.departure).font(.title3.bold())
                    Text(trip.departureTerminal.map { "T\($0)" } ?? " ").font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(trip.arrival).font(.title3.bold())
                    Text(" ").font(.caption2)
                }
            }
            Text(countdown(trip)).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(trip.statusKind.color)
        }
        .padding(.vertical, 4)
    }

    private func countdown(_ trip: WatchTrip) -> String {
        let now = Date()
        let target = now < trip.departureDate ? trip.departureDate : trip.arrivalDate
        let minutes = max(0, Int(target.timeIntervalSince(now) / 60))
        let label = now < trip.departureDate ? "to boarding" : "to landing"
        let value = minutes >= 60 ? "\(minutes / 60)h\(minutes % 60)m" : "\(minutes)m"
        return "\(value) \(label)"
    }
}

private struct TripRow: View {
    let trip: WatchTrip
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(trip.flightNumber).font(.subheadline.weight(.semibold))
                Spacer()
                Text(trip.departureDate, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
            Text("\(trip.departure) → \(trip.arrival)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private extension WatchStatusKind {
    var color: Color {
        switch self {
        case .scheduled: .secondary
        case .live: .blue
        case .good: .green
        case .warn: .orange
        case .bad: .red
        }
    }
}
