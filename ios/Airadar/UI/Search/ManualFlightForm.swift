import SwiftUI

/// For flights no source knows: the traveller types the facts. Airports are
/// resolved by IATA code through the server so the map and zones still work.
struct ManualFlightForm: View {
    var flightNumber: String
    var date: Date
    let onAdd: (Flight) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var number: String
    @State private var airline = ""
    @State private var from = ""
    @State private var to = ""
    @State private var depTime: Date
    @State private var arrTime: Date
    @State private var depTerminal = ""
    @State private var arrTerminal = ""
    @State private var busy = false
    @State private var error: String?

    init(flightNumber: String, date: Date, onAdd: @escaping (Flight) -> Void) {
        self.flightNumber = flightNumber; self.date = date; self.onAdd = onAdd
        _number = State(initialValue: flightNumber)
        let start = Calendar.current.startOfDay(for: date)
        _depTime = State(initialValue: Calendar.current.date(byAdding: .hour, value: 9, to: start) ?? date)
        _arrTime = State(initialValue: Calendar.current.date(byAdding: .hour, value: 12, to: start) ?? date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Flight") {
                    TextField("Flight number", text: $number).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Airline (optional)", text: $airline)
                }
                Section("Route") {
                    HStack {
                        TextField("From (IATA)", text: $from).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        TextField("Terminal", text: $depTerminal).frame(width: 90)
                    }
                    HStack {
                        TextField("To (IATA)", text: $to).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        TextField("Terminal", text: $arrTerminal).frame(width: 90)
                    }
                }
                Section("Times (local at each airport)") {
                    DatePicker("Departure", selection: $depTime)
                    DatePicker("Arrival", selection: $arrTime)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("Add manually")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Adding…" : "Add") { add() }
                        .disabled(busy || number.count < 3 || from.count != 3 || to.count != 3)
                }
            }
        }
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
            var f = Flight(
                id: "\(code)-\(depLocal.dayString)",
                flightNumber: code,
                airlineName: airline.isEmpty ? String(code.prefix(2)) : airline,
                departure: dep, arrival: arr,
                departureTerminal: depTerminal.isEmpty ? nil : depTerminal,
                arrivalTerminal: arrTerminal.isEmpty ? nil : arrTerminal,
                departureTime: depLocal, arrivalTime: arrLocal,
                status: depLocal.date(in: a.zone) < Date() ? .completed : .scheduled
            )
            f.isManual = true
            f.callsign = AirportDatabase.shared.airlineIcao(String(code.prefix(2))).map { $0 + code.dropFirst(2) }
            onAdd(f)
            dismiss()
        }
    }
}
