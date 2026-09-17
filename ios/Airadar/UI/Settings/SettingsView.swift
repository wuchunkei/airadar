import SwiftUI

/// Account (Google sign-in — no token page while Entitlements.paywallEnabled
/// is off), Import, Display, Trips, About.
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var store: FlightStore

    @State private var busy = false
    @State private var authError: String?
    @State private var calendarStatus: String?
    @State private var pickingCalendars = false
    @State private var nameSheet: NameSheet?
    @State private var confirmDeleteAll = false

    var body: some View {
        List {
            Section("Account") { account }
            // Importing needs an account to attach the trips to.
            if auth.isSignedIn {
                Section("Import") {
                    NavigationLink("Read trips from email") { EmailImportView() }
                    Toggle("Read trips from calendar", isOn: calendarBinding)
                    if settings.calendarSync {
                        Button("Choose calendars…") { pickingCalendars = true }
                    }
                    if let calendarStatus { Text(calendarStatus).font(.caption).foregroundStyle(.tint) }
                }
            }
            Section("Display") {
                Picker("Appearance", selection: $settings.themeMode) {
                    Text("System").tag(ThemeMode.system); Text("Light").tag(ThemeMode.light); Text("Dark").tag(ThemeMode.dark)
                }
                .pickerStyle(.segmented)
                Toggle("Show times in my time zone", isOn: $settings.forceSystemZone)
            }
            Section("Trips") {
                NavigationLink("Recycle Bin") { RecycleBinView() }
                Button("Delete all trips", role: .destructive) { confirmDeleteAll = true }
                    .disabled(store.flights.isEmpty)
            }
            Section("About") {
                LabeledContent("Version", value: "1.0.0")
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $nameSheet) { n in
            PassengerNameSheet(title: n.fromGoogle ? "Is this your name?" : "Name on tickets",
                               intro: n.fromGoogle
                                   ? "Taken from your Google account. Airadar uses it only to recognise which imported flights are yours and to let friends recognise you — never to analyse your trips. Skip it if you will not use those features."
                                   : "Used only to recognise your flights and let friends recognise you.",
                               given: n.given, middle: n.middle, family: n.family,
                               onSave: { saveName($0) }, onSkip: { nameSheet = nil })
        }
        .sheet(isPresented: $pickingCalendars) {
            CalendarPicker(preselected: settings.calendarIds,
                           onDone: { ids in pickingCalendars = false; settings.calendarIds = ids; readCalendars() },
                           onCancel: { pickingCalendars = false; if settings.calendarIds.isEmpty { settings.calendarSync = false } })
        }
        .confirmationDialog("Delete all \(store.flights.count) trips?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They go to the Recycle Bin for \(FlightStore.retentionDays) days, so this can be undone.")
        }
    }

    @ViewBuilder
    private var account: some View {
        if auth.isSignedIn, let user = auth.user {
            HStack {
                VStack(alignment: .leading) {
                    // The traveller's name in their own colour — how friends see them.
                    Text(user.name ?? "Signed in").font(.body.weight(.semibold))
                        .foregroundStyle(user.color.map { Color(hex: $0) } ?? .primary)
                    Text(user.email).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign out") { Task { await BackendClient.signOut(); store.onSignedOut() } }
            }
            Toggle("Friends can find me by email", isOn: findableBinding(user.findableByEmail))
            HStack {
                Text("Name on tickets")
                Spacer()
                Button(user.passengerName ?? "Not set") {
                    let p = PassengerNameSheet.parts(of: user.passengerName ?? user.name ?? "")
                    nameSheet = NameSheet(fromGoogle: false, given: p.given, middle: p.middle, family: p.family)
                }
                    .foregroundStyle(user.passengerName == nil ? .secondary : .primary)
            }
        } else {
            // No token gate right now (Entitlements.paywallEnabled is off) —
            // signing in is the only step, and it unlocks everything at once.
            // One row, transparent, so the grouped list draws no card behind it.
            VStack(spacing: 10) {
                Button { signIn() } label: {
                    Group { if busy { ProgressView() } else { Text("Continue with Google").fontWeight(.semibold) } }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent).disabled(busy)
                if let authError { Text(authError).font(.caption).foregroundStyle(.red) }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    private func findableBinding(_ current: Bool) -> Binding<Bool> {
        Binding(get: { current }, set: { on in Task { try? await BackendClient.updateProfile(findableByEmail: on) } })
    }

    private func signIn() {
        busy = true; authError = nil
        Task {
            defer { busy = false }
            do {
                let google = try await GoogleAuth.idToken()
                _ = try await BackendClient.signInWithGoogle(idToken: google.idToken)
                let me = try? await BackendClient.me()
                try? await store.syncFromServer()
                // First sign-in: is the account's name the one on their tickets?
                // Asked once per account; a skip is remembered, the name can be set from Settings later.
                let askedKey = "namePromptShown:" + (me?.email ?? "")
                if me?.passengerName == nil, !UserDefaults.standard.bool(forKey: askedKey) {
                    UserDefaults.standard.set(true, forKey: askedKey)
                    // Google gives first and last; whatever else the full name holds is the middle.
                    let p = PassengerNameSheet.parts(of: google.fullName ?? me?.name ?? "")
                    let given = google.givenName ?? p.given, family = google.familyName ?? p.family
                    var middle = p.middle
                    if let full = google.fullName {
                        let rest = full.replacingOccurrences(of: given, with: "").replacingOccurrences(of: family, with: "")
                        middle = rest.trimmingCharacters(in: .whitespaces)
                    }
                    nameSheet = NameSheet(fromGoogle: true, given: given, middle: middle, family: family)
                }
            } catch is GoogleAuth.Cancelled {
                // Nothing to say: the traveller closed the picker.
            } catch { authError = error.localizedDescription }
        }
    }

    private struct NameSheet: Identifiable {
        let id = UUID()
        let fromGoogle: Bool
        let given: String, middle: String, family: String
    }

    private func saveName(_ name: String) {
        nameSheet = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { try? await BackendClient.updateProfile(passengerName: trimmed) }
    }

    private var calendarBinding: Binding<Bool> {
        Binding(get: { settings.calendarSync }, set: { setCalendar($0) })
    }

    /// Turning the switch on asks which calendars, then reads them straight away.
    private func setCalendar(_ on: Bool) {
        settings.calendarSync = on
        guard on else { calendarStatus = nil; return }
        pickingCalendars = true
    }

    private func readCalendars() {
        calendarStatus = "Reading calendars"
        Task {
            let found = (try? await CalendarImporter.scan(calendarIds: settings.calendarIds)) ?? []
            let result = await TripImporter.run(found)
            calendarStatus = found.isEmpty ? "No flights found in your calendars."
                : result.added > 0 ? "\(result.added) trips added from your calendars — confirm them in Trips."
                : result.alreadyPresent == found.count ? "Every calendar flight is already in Trips."
                // Found something, but the schedule source could not confirm it — a renumbered,
                // seasonal, or long-past flight, most likely, not a reading failure.
                : "Found \(found.count) but couldn't confirm \(result.unconfirmed.count) (\(result.unconfirmed.prefix(3).map(\.flightNumber).joined(separator: ", "))) against the schedule."
        }
    }
}

/// "Premium · until 2026-10-12", "Superior · grace period", or "No plan".
/// Not shown anywhere right now — the paywall is shelved (see
/// Entitlements.paywallEnabled) — kept for when it comes back.
struct PlanLine: View {
    let membership: Membership
    private var name: String {
        switch membership.tier { case .premium: "Premium"; case .superior: "Superior"; case .guest: "No plan" }
    }
    private var color: Color {
        switch membership.tier {
        case .premium: Color(red: 1, green: 0.82, blue: 0.29)
        case .superior: Color(red: 0.12, green: 0.70, blue: 0.48)
        case .guest: .secondary
        }
    }
    private var suffix: String {
        if membership.grace { return " · Grace period" }
        guard let until = membership.until else { return "" }
        return " · Until " + until.formatted(date: .numeric, time: .omitted)
    }
    var body: some View {
        Text(name + suffix).font(.subheadline.weight(.medium)).foregroundStyle(color)
    }
}
