import SwiftUI

/// For flights no source knows: the traveller types the facts. Airports are
/// resolved by IATA code through the server so the map and zones still work.
/// Doubles as the editor for an existing manual trip — `existing` set means
/// "Save" replaces it rather than adding a new one.
struct ManualFlightForm: View {
    var flightNumber: String
    var date: Date
    var existing: Flight? = nil
    let onAdd: (Flight) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var number: String
    @State private var airline: String
    @State private var from: String
    @State private var to: String
    @State private var depTime: Date
    @State private var arrTime: Date
    @State private var depTerminal: String
    @State private var arrTerminal: String
    @State private var busy = false
    @State private var error: String?

    @State private var showAirlineConfirm = false
    @State private var showAirlinePicker = false
    /// What each airport's own terminals turn out to be, once `from`/`to`
    /// resolves to one — empty means either not resolved yet or nothing found,
    /// and the text field is still there to type one by hand either way.
    @State private var depTerminalOptions: [String] = []
    @State private var arrTerminalOptions: [String] = []

    init(flightNumber: String, date: Date, onAdd: @escaping (Flight) -> Void) {
        self.flightNumber = flightNumber; self.date = date; self.onAdd = onAdd
        _number = State(initialValue: flightNumber)
        _airline = State(initialValue: "")
        _from = State(initialValue: ""); _to = State(initialValue: "")
        _depTerminal = State(initialValue: ""); _arrTerminal = State(initialValue: "")
        let start = Calendar.current.startOfDay(for: date)
        _depTime = State(initialValue: Calendar.current.date(byAdding: .hour, value: 9, to: start) ?? date)
        _arrTime = State(initialValue: Calendar.current.date(byAdding: .hour, value: 12, to: start) ?? date)
    }

    /// Editing a manual trip already on the list — every field starts at what it already has.
    init(editing flight: Flight, onAdd: @escaping (Flight) -> Void) {
        self.flightNumber = flight.flightNumber
        self.date = flight.departureTime.date(in: .current)
        self.existing = flight
        self.onAdd = onAdd
        _number = State(initialValue: flight.flightNumber)
        _airline = State(initialValue: flight.airlineName)
        _from = State(initialValue: flight.departure); _to = State(initialValue: flight.arrival)
        _depTerminal = State(initialValue: flight.departureTerminal ?? "")
        _arrTerminal = State(initialValue: flight.arrivalTerminal ?? "")
        _depTime = State(initialValue: flight.departureTime.date(in: .current))
        _arrTime = State(initialValue: flight.arrivalTime.date(in: .current))
    }

    /// The bundled worldwide table's guess from the flight number's own
    /// prefix — shown until the traveller sets or corrects it.
    private var detectedAirline: String? {
        guard number.count >= 2 else { return nil }
        return AirlineDatabase.shared.airline(iata: String(number.prefix(2)))?.name
    }
    private var shownAirline: String { airline.isEmpty ? (detectedAirline ?? "") : airline }

    var body: some View {
        NavigationStack {
            Form {
                Section("Flight") {
                    TextField("Flight number", text: $number).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    HStack {
                        Text("Airline")
                        Spacer()
                        Button {
                            if shownAirline.isEmpty { showAirlinePicker = true } else { showAirlineConfirm = true }
                        } label: {
                            Text(shownAirline.isEmpty ? "Tap to set" : shownAirline).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Route") {
                    HStack {
                        TextField("From (IATA)", text: $from).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        terminalField($depTerminal, options: depTerminalOptions)
                    }
                    HStack {
                        TextField("To (IATA)", text: $to).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        terminalField($arrTerminal, options: arrTerminalOptions)
                    }
                }
                Section("Times (local at each airport)") {
                    DatePicker("Departure", selection: $depTime)
                    DatePicker("Arrival", selection: $arrTime)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle(existing == nil ? "Add manually" : "Edit trip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : (existing == nil ? "Add" : "Save")) { add() }
                        .disabled(busy || number.count < 3 || from.count != 3 || to.count != 3)
                }
            }
            // Tapping the shown airline: confirm it's actually right before leaving it alone,
            // so a correct auto-detected guess isn't second-guessed by accident. A centred
            // alert, not a bottom sheet — this is a yes/no question, not a menu of actions.
            .alert("Is the airline correct?", isPresented: $showAirlineConfirm) {
                Button("Yes", role: .cancel) {}
                Button("No") { showAirlinePicker = true }
            }
            .sheet(isPresented: $showAirlinePicker) {
                AirlinePickerSheet(flightNumber: number) { name in airline = name }
            }
            // Whichever airport is typed, its own terminals get looked up quietly —
            // cancelled and restarted on every keystroke, so only the pause after
            // typing actually finishes one.
            .task(id: from) { depTerminalOptions = await Self.lookupTerminals(from) }
            .task(id: to) { arrTerminalOptions = await Self.lookupTerminals(to) }
        }
    }

    /// A little dropdown beside the free-text field — a terminal typed by hand
    /// still works (a small airfield may have nothing worth looking up), but
    /// once the airport's own terminals are known, picking one beats typing it.
    @ViewBuilder
    private func terminalField(_ text: Binding<String>, options: [String]) -> some View {
        HStack(spacing: 2) {
            TextField("Terminal", text: text)
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(TerminalDiscovery.displayLabel(option)) { text.wrappedValue = option }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle.fill").foregroundStyle(.secondary).font(.caption)
                }
            }
        }
        .frame(width: 130)
    }

    private static func lookupTerminals(_ iata: String) async -> [String] {
        let code = iata.uppercased()
        guard code.count == 3 else { return [] }
        await AirportDatabase.shared.ensure(code) { try await BackendClient.airport(code) }
        guard let airport = AirportDatabase.shared.airport(code) else { return [] }
        return await TerminalDiscovery.availableTerminals(for: airport)
    }

    private func add() {
        busy = true; error = nil
        let dep = from.uppercased(), arr = to.uppercased(), code = number.uppercased()
        Task {
            defer { busy = false }
            // Both airports must be placeable: fetch what the bundled table lacks.
            for iata in [dep, arr] {
                await AirportDatabase.shared.ensure(iata) { try await BackendClient.airport(iata) }
            }
            guard let a = AirportDatabase.shared.airport(dep) else { error = "Unknown airport \(dep)."; return }
            guard let b = AirportDatabase.shared.airport(arr) else { error = "Unknown airport \(arr)."; return }
            // The pickers run in the phone's zone; the clock times are what count.
            let depLocal = LocalDateTime.from(depTime, in: .current)
            let arrLocal = LocalDateTime.from(arrTime, in: .current)
            _ = a; _ = b
            var f = existing ?? Flight(
                id: "\(code)-\(depLocal.dayString)", flightNumber: code, airlineName: "",
                departure: dep, arrival: arr, departureTime: depLocal, arrivalTime: arrLocal, status: .scheduled)
            // Recomputed even when editing: a changed number or date is a changed identity,
            // and FlightStore.replace already knows how to move the old id's data to a new one.
            f.id = "\(code)-\(depLocal.dayString)"
            f.flightNumber = code
            f.airlineName = shownAirline.isEmpty ? String(code.prefix(2)) : shownAirline
            f.departure = dep; f.arrival = arr
            f.departureTerminal = depTerminal.isEmpty ? nil : depTerminal
            f.arrivalTerminal = arrTerminal.isEmpty ? nil : arrTerminal
            f.departureTime = depLocal; f.arrivalTime = arrLocal
            f.status = depLocal.date(in: a.zone) < Date() ? .completed : .scheduled
            f.isManual = true
            f.callsign = f.callsign ?? AirportDatabase.shared.airlineIcao(String(code.prefix(2))).map { $0 + code.dropFirst(2) }
            onAdd(f)
            dismiss()
        }
    }
}

/// The airline picker: search-as-you-type over the bundled worldwide table,
/// or "Other" for one it doesn't have — which stages a suggestion rather than
/// just silently accepting whatever was typed.
struct AirlinePickerSheet: View {
    let flightNumber: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showOther = false

    private var results: [AirlineInfo] { AirlineDatabase.shared.search(query) }

    var body: some View {
        NavigationStack {
            List {
                if !results.isEmpty {
                    Section {
                        ForEach(results, id: \.iata) { a in
                            Button {
                                onSelect(a.name)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).foregroundStyle(.primary)
                                    Text("\(a.iata)\(a.icao.isEmpty ? "" : " / \(a.icao)")\(a.country.isEmpty ? "" : " · \(a.country)")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            // Without this a List row's Button tints its whole label with the
                            // accent colour (blue), regardless of foregroundStyle above.
                            .buttonStyle(.plain)
                        }
                    }
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No match in the bundled list.").font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Button("Other — my airline isn't listed") { showOther = true }
                }
            }
            .searchable(text: $query, prompt: "Search airline name or code")
            .navigationTitle("Airline")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showOther) {
                OtherAirlineSheet(flightNumber: flightNumber) { name in
                    onSelect(name)
                    showOther = false
                    dismiss()
                }
            }
        }
    }
}

/// An airline the bundled table doesn't know — used right away, and staged as
/// a suggestion (see `AirlineSuggestionStore`) for a real review later.
private struct OtherAirlineSheet: View {
    let flightNumber: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Airline name") {
                    TextField("e.g. Some New Airline", text: $name)
                }
                Text("Not in the bundled list yet — this trip uses the name you type right away, and it's kept on this device to review adding properly later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Suggest an airline")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        AirlineSuggestionStore.shared.submit(flightNumber: flightNumber, name: trimmed)
                        onSubmit(trimmed)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
