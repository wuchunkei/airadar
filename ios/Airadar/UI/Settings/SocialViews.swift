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

/// Guest / Premium side by side, plus the separate Share add-on; shown
/// whenever a plan limit is hit, and from Settings.
struct MembershipView: View {
    let current: Tier
    let canShare: Bool
    let reason: String?
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    private struct PlanRow: Identifiable { let feature: String, guest: String, premium: String; var id: String { feature } }
    private let rows: [PlanRow] = [
        PlanRow(feature: "Trips ahead", guest: "1 at a time", premium: "Unlimited"),
        PlanRow(feature: "Past trips", guest: "Last 7 days", premium: "Unlimited"),
        PlanRow(feature: "Add ahead", guest: "Any date", premium: "Any date"),
        PlanRow(feature: "Cloud sync", guest: "Last 7 days", premium: "Unlimited"),
        PlanRow(feature: "Reminders & tiers", guest: "✓", premium: "✓"),
        PlanRow(feature: "Search a flight", guest: "✓", premium: "✓"),
        PlanRow(feature: "Recycle bin", guest: "—", premium: "✓"),
        PlanRow(feature: "Flown tracks", guest: "—", premium: "✓"),
        PlanRow(feature: "Gmail & calendar import", guest: "—", premium: "✓"),
        PlanRow(feature: "Price", guest: "Free", premium: Plans.premiumPrice),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let reason { Text(reason).foregroundStyle(.red) }
                    Grid(horizontalSpacing: 6, verticalSpacing: 8) {
                        GridRow { Text(""); cell("Guest", .guest, header: true); cell("Premium", .premium, header: true) }
                        Divider()
                        ForEach(rows) { r in
                            GridRow {
                                Text(r.feature).font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                                cell(r.guest, .guest)
                                cell(r.premium, .premium)
                            }
                        }
                    }
                    Divider().padding(.vertical, 4)
                    // Not a tier column -- its own small subscription, held
                    // or not regardless of Guest/Premium.
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share").font(.subheadline.weight(.semibold))
                            Text("Send trips to friends — \(Plans.sharePrice)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: canShare ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(canShare ? Color.accentColor : .secondary)
                    }
                    Text("Premium is bought on the web (monthly, or once as a lifetime buyout) and unlocked in the app with a token; a subscription keeps working for 3 days after a period ends.")
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
/// One found via a shared calendar gets an extra question first — whose trip is
/// this actually? A shared calendar surfaces a partner's or family member's
/// flights too, not just the phone owner's.
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

    /// "Mine!" just dismisses the question; "Is friend's?" opens the picker below.
    @State private var confirmedMine = false
    @State private var showFriendPicker = false
    @State private var sharedWith: Friend?

    init(flight: Flight, onConfirm: @escaping (Flight) -> Void, onReplace: @escaping (Flight, Flight) -> Void, onDismiss: @escaping () -> Void) {
        self.flight = flight; self.onConfirm = onConfirm; self.onReplace = onReplace; self.onDismiss = onDismiss
        _number = State(initialValue: flight.flightNumber)
        _date = State(initialValue: flight.departureTime.date(in: flight.departureAirport?.zone ?? .current))
    }

    @EnvironmentObject private var store: FlightStore
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        // The flight in full, as any other card opens, with the verdict stacked underneath.
        let shown = found ?? flight
        FlightDetailSheet(
            flight: shown, forceSystemZone: settings.forceSystemZone, onDismiss: onDismiss,
            primaryAction: primary, secondaryAction: secondary,
            extraActions: {
                if editing {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Not this one? Change the number or date and search again.").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Flight number", text: $number).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .font(.body.monospaced()).padding(12)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.red, lineWidth: 1.5))
                        DatePicker("Date", selection: $date, displayedComponents: .date).datePickerStyle(.compact)
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                        if found != nil {
                            Button("Still wrong? Send feedback") { openURL(URL(string: "https://t.me/wuchunkei")!) }.font(.caption)
                        }
                    }
                } else if flight.importedVia == "calendar" {
                    if let sharedWith {
                        // The share itself is what shows the "pending" block on the card
                        // from here — this trip's own Correct/Incorrect still works too,
                        // in case the friend says it wasn't theirs after all.
                        Text("Shared with \(sharedWith.person.givenName) to confirm.").font(.caption).foregroundStyle(.secondary)
                    } else if !confirmedMine {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Found via a shared calendar — whose trip is this?").font(.subheadline).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button("Mine!") { confirmedMine = true }.buttonStyle(.bordered)
                                Button("Is friend's?") { showFriendPicker = true }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            })
        .sheet(isPresented: $showFriendPicker) {
            FriendSharePicker { friend in
                sharedWith = friend
                Task { try? await store.share(flight, with: friend.person) }
            }
        }
    }

    private var primary: (label: String, action: () -> Void) {
        if !editing { return ("Correct", { onConfirm(flight) }) }
        if let found { return ("Save this flight", { onReplace(flight, found) }) }
        return (searching ? "Searching…" : "Search", { search() })
    }

    private var secondary: (label: String, action: () -> Void) {
        editing ? ("Discard trip", { onDismiss() }) : ("Incorrect", { editing = true })
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

/// Just "pick a friend" — the plain list a calendar-found trip needs, without
/// the system-share fallback and picture-making `ShareFlow` carries for a real
/// share button.
private struct FriendSharePicker: View {
    let onPick: (Friend) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [Friend]?

    var body: some View {
        NavigationStack {
            Group {
                if let friends {
                    if friends.isEmpty {
                        Text("Add a friend first (My › Settings) to share a trip with them.")
                            .font(.subheadline).foregroundStyle(.secondary).padding()
                    } else {
                        List(friends) { f in
                            Button { onPick(f); dismiss() } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(f.person.tint).frame(width: 32, height: 32)
                                        .overlay(Text(f.person.givenName.prefix(1).uppercased()).font(.caption.bold()).foregroundStyle(.white))
                                    Text(f.person.givenName).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Whose trip is this?")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { friends = ((try? await BackendClient.friends()) ?? []).filter { $0.status == .accepted } }
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
                    Task {
                        let result = await TripImporter.run(FlightEmailParser.candidates(pasted))
                        status = result.added > 0 ? "\(result.added) trips added — confirm them in Trips."
                            : result.unconfirmed.isEmpty ? "No new flights recognised."
                            : "Recognised \(result.unconfirmed.map(\.flightNumber).joined(separator: ", ")), but couldn't confirm against the schedule: \(result.unconfirmed.first?.reason ?? "")"
                    }
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
                let result = await TripImporter.run(found) { done, total in status = "Checking flight \(done) of \(total)" }
                status = found.isEmpty ? "No mail mentioning a flight in the last two years."
                    : result.added > 0 ? "\(result.added) trips added — open each one in Trips to confirm."
                    : result.alreadyPresent == found.count ? "Read \(found.count) candidates; every flight is already in Trips."
                    : "Read \(found.count) candidates; \(result.unconfirmed.count) couldn't be confirmed against the schedule (renumbered, seasonal, or too far past)."
            } catch { status = error.localizedDescription }
        }
    }
}
