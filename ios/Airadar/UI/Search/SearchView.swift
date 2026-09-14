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

                    if let error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
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
        .sheet(item: $result) { f in
            FlightDetailSheet(flight: f, forceSystemZone: settings.forceSystemZone, onDismiss: { result = nil },
                              primaryAction: ("Add to trips", { result = nil; onAdd(f) }))
        }
    }

    private func search() {
        searching = true; error = nil
        let day = LocalDateTime.from(date, in: .current).dayString
        Task {
            defer { searching = false }
            do { result = try await BackendClient.flight(number, on: day) } catch { self.error = error.localizedDescription }
        }
    }
}
