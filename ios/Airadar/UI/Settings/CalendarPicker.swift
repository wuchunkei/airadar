import SwiftUI
import EventKit

/// Which calendars to read flights from — any number of them, grouped by account.
struct CalendarPicker: View {
    let onDone: ([String]) -> Void
    let onCancel: () -> Void

    @State private var calendars: [EKCalendar] = []
    @State private var chosen: Set<String>
    @State private var denied = false

    init(preselected: [String], onDone: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.onDone = onDone; self.onCancel = onCancel
        _chosen = State(initialValue: Set(preselected))
    }

    private var grouped: [(String, [EKCalendar])] {
        let bySource = Dictionary(grouping: calendars) { $0.source?.title ?? "Other" }
        return bySource.keys.sorted().map { ($0, bySource[$0]!.sorted { $0.title < $1.title }) }
    }

    var body: some View {
        NavigationStack {
            List {
                if denied {
                    Text("Calendar access was refused. Allow it under Settings › Privacy & Security › Calendars.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(grouped, id: \.0) { source, list in
                    Section(source) {
                        ForEach(list, id: \.calendarIdentifier) { cal in
                            Toggle(isOn: Binding(
                                get: { chosen.contains(cal.calendarIdentifier) },
                                set: { on in if on { chosen.insert(cal.calendarIdentifier) } else { chosen.remove(cal.calendarIdentifier) } }
                            )) {
                                HStack(spacing: 10) {
                                    Circle().fill(Color(cgColor: cal.cgColor)).frame(width: 10, height: 10)
                                    Text(cal.title)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Calendars to read")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Read") { onDone(Array(chosen)) }.disabled(chosen.isEmpty) }
            }
            .task {
                let store = EKEventStore()
                guard (try? await store.requestFullAccessToEvents()) == true else { denied = true; return }
                let all = store.calendars(for: .event)
                calendars = all
                // First time: everything ticked; the traveller unticks what is not theirs.
                if chosen.isEmpty { chosen = Set(all.map(\.calendarIdentifier)) }
            }
        }
    }
}
