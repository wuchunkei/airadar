import SwiftUI

/// Friends: requests waiting on me, the people I share with, requests I sent.
struct FriendsView: View {
    @State private var friends: [Friend] = []
    @State private var email = ""
    @State private var found: Person?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Find by email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Find") { find() }.buttonStyle(.glass).disabled(!email.contains("@"))
                }
                if let p = found {
                    PersonRow(person: p) {
                        Button("Add friend") { add(p) }.buttonStyle(.glassProminent)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
            }
            let incoming = friends.filter { $0.status == .incoming }
            if !incoming.isEmpty {
                Section("Requests") {
                    ForEach(incoming) { f in
                        PersonRow(person: f.person) {
                            Button("Decline") { remove(f) }
                            Button("Accept") { accept(f) }.buttonStyle(.glassProminent)
                        }
                    }
                }
            }
            Section("Friends") {
                let accepted = friends.filter { $0.status == .accepted }
                if accepted.isEmpty { Text("No friends yet. Find someone by email, or accept a request from a shared trip.").font(.caption).foregroundStyle(.secondary) }
                ForEach(accepted) { f in
                    PersonRow(person: f.person) { Button("Remove") { remove(f) } }
                }
            }
            let outgoing = friends.filter { $0.status == .outgoing }
            if !outgoing.isEmpty {
                Section("Sent") {
                    ForEach(outgoing) { f in
                        PersonRow(person: f.person) { Button("Cancel") { remove(f) } }
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .task { await reload() }
    }

    private func reload() async { friends = (try? await BackendClient.friends()) ?? [] }

    private func find() {
        Task {
            do { found = try await BackendClient.lookup(email: email); message = nil }
            catch { found = nil; message = error.localizedDescription }
        }
    }
    private func add(_ p: Person) { Task { _ = try? await BackendClient.requestFriend(p.id); found = nil; email = ""; await reload() } }
    private func accept(_ f: Friend) { Task { try? await BackendClient.acceptFriend(f.friendshipId); await reload() } }
    private func remove(_ f: Friend) { Task { try? await BackendClient.removeFriend(f.friendshipId); await reload() } }
}

struct PersonRow<Trailing: View>: View {
    let person: Person
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack {
            Circle().fill(person.tint).frame(width: 32, height: 32)
                .overlay(Text(person.givenName.prefix(1).uppercased()).font(.subheadline.bold()).foregroundStyle(.white))
            Text(person.givenName).fontWeight(.medium).foregroundStyle(person.tint)
            Spacer()
            trailing()
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Deleted trips, kept for 30 days; the sheet ends in a Restore button behind a confirm.
struct RecycleBinView: View {
    @EnvironmentObject private var store: FlightStore
    @EnvironmentObject private var settings: SettingsModel
    @State private var selected: Flight?
    @State private var confirm = false

    var body: some View {
        List {
            if store.deleted.isEmpty {
                Text("Nothing here. Deleted trips stay for \(FlightStore.retentionDays) days.").foregroundStyle(.secondary)
            }
            ForEach(store.deleted) { f in
                VStack(alignment: .leading, spacing: 4) {
                    FlightCard(flight: f, forceSystemZone: settings.forceSystemZone) { selected = f }
                    if let d = f.deletedAt {
                        let left = max(0, FlightStore.retentionDays - Int(Date().timeIntervalSince(d) / 86400))
                        let when = d.formatted(date: .numeric, time: .omitted)
                        let days = left == 1 ? "1 day" : "\(left) days"
                        Text("Deleted \(when) · gone for good in \(days)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Recycle Bin")
        .sheet(item: $selected) { f in
            FlightDetailSheet(flight: f, forceSystemZone: settings.forceSystemZone, onDismiss: { selected = nil },
                              primaryAction: ("Restore", { confirm = true }))
                .alert("Restore this trip?", isPresented: $confirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Confirm") { store.restore(f.id); FlightReminders.schedule(f); selected = nil }
                } message: { Text("\(f.flightNumber) goes back to your trips, reminders included.") }
        }
    }
}

/// Guest / Superior / Premium side by side; shown whenever a plan limit is hit, and from Settings.
struct MembershipView: View {
    let current: Tier
    let reason: String?
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    private struct PlanRow: Identifiable { let feature: String, guest: String, superior: String, premium: String; var id: String { feature } }
    private let rows: [PlanRow] = [
        PlanRow(feature: "Trips ahead", guest: "3 in all", superior: "10", premium: "Unlimited"),
        PlanRow(feature: "Past trips", guest: "1", superior: "5", premium: "Unlimited"),
        PlanRow(feature: "Add ahead", guest: "7 days", superior: "30 days", premium: "Any date"),
        PlanRow(feature: "Cloud sync", guest: "—", superior: "✓", premium: "✓"),
        PlanRow(feature: "Friends & sharing", guest: "—", superior: "✓", premium: "✓"),
        PlanRow(feature: "Recycle bin", guest: "—", superior: "✓", premium: "✓"),
        PlanRow(feature: "Flown tracks", guest: "—", superior: "—", premium: "✓"),
        PlanRow(feature: "Gmail & calendar import", guest: "—", superior: "—", premium: "✓"),
        PlanRow(feature: "Price", guest: "Free", superior: Plans.superiorPrice, premium: Plans.premiumPrice),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let reason { Text(reason).foregroundStyle(.red) }
                    Grid(horizontalSpacing: 6, verticalSpacing: 8) {
                        GridRow { Text(""); cell("Guest", .guest, header: true); cell("Superior", .superior, header: true); cell("Premium", .premium, header: true) }
                        Divider()
                        ForEach(rows) { r in
                            GridRow {
                                Text(r.feature).font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                                cell(r.guest, .guest)
                                cell(r.superior, .superior)
                                cell(r.premium, .premium)
                            }
                        }
                    }
                    Text("Plans are bought on the web and unlocked in the app with a token. Paid plans keep working for 3 days after a period ends.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button { openURL(Plans.payURL) } label: { Text("Get a plan on the web").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.glassProminent)
                }
                .padding(20)
            }
            .navigationTitle("Plans")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close", action: onDismiss) } }
        }
    }

    private func cell(_ text: String, _ tier: Tier, header: Bool = false) -> some View {
        Text(text).font(header ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(tier == current ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(tier == current ? Color.accentColor.opacity(0.08) : .clear)
    }
}

/// An imported trip waiting for a yes: Correct / Incorrect, then edit → Search, then Save.
struct PendingFlightSheet: View {
    let flight: Flight
    let onConfirm: (Flight) -> Void
    let onReplace: (Flight, Flight) -> Void
    let onDismiss: () -> Void

    @State private var editing = false
    @State private var number: String
    @State private var date: Date
    @State private var searching = false
    @State private var found: Flight?
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    init(flight: Flight, onConfirm: @escaping (Flight) -> Void, onReplace: @escaping (Flight, Flight) -> Void, onDismiss: @escaping () -> Void) {
        self.flight = flight; self.onConfirm = onConfirm; self.onReplace = onReplace; self.onDismiss = onDismiss
        _number = State(initialValue: flight.flightNumber)
        _date = State(initialValue: flight.departureTime.date(in: flight.departureAirport?.zone ?? .current))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Is this right?").font(.title2.bold())
            let shown = found ?? flight
            Text("\(shown.flightNumber) · \(shown.departure) → \(shown.arrival) · \(shown.departureDay)")
            if editing {
                TextField("Flight number", text: $number).textInputAutocapitalization(.characters).padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.red, lineWidth: 1.5))
                DatePicker("Date", selection: $date, displayedComponents: .date).datePickerStyle(.compact)
                HStack {
                    Button("Discard") { onDismiss() }.buttonStyle(.glass).tint(.red).frame(maxWidth: .infinity)
                    Button(searching ? "Searching…" : "Search") { search() }.buttonStyle(.glassProminent).tint(.blue).frame(maxWidth: .infinity).disabled(searching)
                }
                if let found {
                    HStack {
                        Button("Feedback") { openURL(URL(string: "https://t.me/wuchunkei")!) }.buttonStyle(.glass).tint(.yellow).frame(maxWidth: .infinity)
                        Button("Save") { onReplace(flight, found) }.buttonStyle(.glassProminent).tint(.green).frame(maxWidth: .infinity)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } else {
                HStack {
                    Button("Incorrect") { editing = true }.buttonStyle(.glass).tint(.red).frame(maxWidth: .infinity)
                    Button("Correct") { onConfirm(flight) }.buttonStyle(.glassProminent).tint(.green).frame(maxWidth: .infinity)
                }
            }
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    private func search() {
        searching = true; error = nil
        let day = LocalDateTime.from(date, in: .current).dayString
        Task {
            defer { searching = false }
            do { var f = try await BackendClient.flight(number, on: day); f.isPending = false; found = f } catch { self.error = error.localizedDescription }
        }
    }
}

/// Trips out of Gmail: Google's consent sheet grants read access, the mailbox is
/// searched for anything that mentions a flight, every pair checked against the timetable.
struct EmailImportView: View {
    @State private var status: String?
    @State private var busy = false
    @State private var pasted = ""

    var body: some View {
        Form {
            Section {
                Button { readGmail() } label: { HStack { if busy { ProgressView() }; Text("Read my Gmail").fontWeight(.semibold) } }
                    .disabled(busy)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Or paste a booking confirmation") {
                TextEditor(text: $pasted).frame(minHeight: 140)
                Button("Scan the text") {
                    Task { let n = await TripImporter.run(FlightEmailParser.candidates(pasted)); status = n == 0 ? "No new flights recognised." : "\(n) trips added — confirm them in Trips." }
                }
                .disabled(pasted.isEmpty)
            }
        }
        .navigationTitle("Import from email")
    }

    private func readGmail() {
        busy = true; status = "Asking Google for access"
        Task {
            defer { busy = false }
            do {
                let token = try await GoogleAuth.gmailAccessToken()
                status = "Searching the mailbox"
                let found = try await GmailImporter.scan(accessToken: token) { p in Task { @MainActor in status = "Reading mail \(p.scanned) of \(p.total)" } }
                let added = await TripImporter.run(found) { done, total in status = "Checking flight \(done) of \(total)" }
                status = found.isEmpty ? "No mail mentioning a flight in the last two years."
                    : added == 0 ? "Read \(found.count) candidates; every flight is already in Trips."
                    : "\(added) trips added — open each one in Trips to confirm."
            } catch { status = error.localizedDescription }
        }
    }
}
