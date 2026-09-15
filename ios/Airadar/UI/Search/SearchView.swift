import SwiftUI

/// Flight number + departure date → the detail sheet with "Add to trips".
struct SearchView: View {
    let onAdd: (Flight) -> Void
    @EnvironmentObject private var settings: SettingsModel

    @State private var number = ""
    @State private var date = Date()
    @State private var showPicker = false
    @State private var searching = false
    @State private var error: String?
    @State private var result: Flight?
    @State private var showManual = false
    /// More than one real candidate for this number around this date — a
    /// simple card each, earliest first, to pick the one that's actually theirs.
    @State private var candidates: [Flight] = []
    @State private var showCandidates = false

    private static let shown: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "yyyy-MM-dd (EEEE)"; return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    TextField("Flight number", text: $number)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onChange(of: number) { number = number.uppercased().filter { $0.isLetter || $0.isNumber } }
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))

                    Button { showPicker = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Departure date").font(.caption).foregroundStyle(.secondary)
                                Text(Self.shown.string(from: date)).font(.body)
                            }
                            Spacer()
                            Image(systemName: "calendar").foregroundStyle(.tint)
                        }
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    Button(action: search) {
                        Group { if searching { ProgressView().tint(.white) } else { Text("Search flight").fontWeight(.semibold) } }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(number.count < 3 || searching)

                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        // No source knew it: let the traveller record it by hand.
                        Button { showManual = true } label: {
                            Text("Add manually").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Search")
        }
        .sheet(isPresented: $showPicker) {
            // The three-column wheel — year, month, day — the platform's own.
            VStack {
                DatePicker("Departure date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "en_US"))
                Button("Done") { showPicker = false }.buttonStyle(.glassProminent).padding(.bottom)
            }
            .presentationDetents([.height(320)])
        }
        .sheet(isPresented: $showManual) {
            ManualFlightForm(flightNumber: number, date: date) { flight in
                error = nil
                onAdd(flight)
            }
        }
        .sheet(item: $result) { f in
            FlightDetailSheet(flight: f, forceSystemZone: settings.forceSystemZone, onDismiss: { result = nil },
                              primaryAction: ("Add to trips", { result = nil; onAdd(f) }))
        }
        .sheet(isPresented: $showCandidates) {
            CandidatePickerSheet(flights: candidates) { chosen in
                showCandidates = false
                result = chosen
            }
        }
    }

    private func search() {
        searching = true; error = nil
        let day = LocalDateTime.from(date, in: .current).dayString
        Task {
            defer { searching = false }
            do {
                let found = try await BackendClient.flightCandidates(number, on: day)
                if found.count <= 1 { result = found.first }
                else { candidates = found; showCandidates = true }
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// The same number really runs more than once around the asked-for date — a
/// simple card each (the same one Trip uses), earliest departure at the top,
/// instead of guessing which one a person meant.
private struct CandidatePickerSheet: View {
    let flights: [Flight]
    let onPick: (Flight) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Text("This flight number runs more than once around this date — which one is yours?")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(flights) { f in
                        FlightCard(flight: f, forceSystemZone: settings.forceSystemZone) { onPick(f) }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Choose a flight")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
