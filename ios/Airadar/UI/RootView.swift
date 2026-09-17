import SwiftUI

enum AppTab: Hashable { case trip, search, community, my }

/// Trip / Search / Community / My. On iOS 26 the tab bar is Liquid Glass by
/// itself; the per-screen floating controls use `.glassEffect` to match.
struct RootView: View {
    @EnvironmentObject private var store: FlightStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var settings: SettingsModel
    @StateObject private var links = DeepLinks.shared

    @State private var tab: AppTab = .trip
    @State private var tripResetSignal = 0

    /// Imported trips still waiting to be confirmed — the dashed cards,
    /// Coming and Past together now that they share one tab.
    private var pendingTrips: Int { store.flights.filter(\.isPending).count }
    @State private var linked: BackendClient.LinkedTrip?
    @State private var toast: String?

    private var canShare: Bool { auth.isSignedIn && (auth.user?.membership.limits.sharing ?? false) }

    private func deleted(_ flight: Flight) {
        FlightReminders.cancel(flight.id)
        toast = flight.sharedBy == nil
            ? "Moved to the Recycle Bin. Restore it from My › Settings › Recycle Bin within 30 days."
            : "Declined."
    }

    private func addLinked(_ link: BackendClient.LinkedTrip) {
        Task {
            var added = false
            if auth.isSignedIn, let token = links.shareToken {
                added = (try? await BackendClient.copyLinkedTrip(token)) != nil
                try? await store.syncFromServer()
            } else {
                added = store.add(link.flight)
            }
            if added { FlightReminders.schedule(link.flight); tab = .trip }
            linked = nil
            links.shareToken = nil
        }
    }

    var body: some View {
        TabView(selection: Binding(get: { tab }, set: { new in
            if new == .trip && tab == .trip { tripResetSignal += 1 }
            tab = new
        })) {
            Tab("Trip", systemImage: "airplane.departure", value: .trip) {
                TripView(resetSignal: tripResetSignal, canShare: canShare, onDeleted: deleted)
            }
            .badge(pendingTrips)
            Tab("Search", systemImage: "magnifyingglass", value: .search) {
                SearchView(onAdd: { flight in
                    // A refusal opens the plans dialog by itself; stay on Search then.
                    if store.add(flight) {
                        FlightReminders.schedule(flight)
                        tab = .trip
                    }
                })
            }
            Tab("Community", systemImage: "person.3", value: .community) {
                CommunityView()
            }
            Tab("My", systemImage: "map", value: .my) {
                MyView()
            }
        }
        .tint(.accentColor)
        // A plan limit was hit somewhere: explain, offer more.
        .sheet(item: $store.limitHit) { hit in
            MembershipView(current: Entitlements.membership.tier, reason: hit.reason) { store.limitHit = nil }
                .presentationDetents([.large])
        }
        // A trip someone sent as a link — plan holders only; a guest does not take part in sharing.
        .task(id: links.shareToken) {
            guard let token = links.shareToken else { return }
            guard canShare else { links.shareToken = nil; return }
            linked = try? await BackendClient.linkedTrip(token)
            if linked == nil { toast = "That trip link has expired."; links.shareToken = nil }
        }
        .sheet(item: $linked, onDismiss: { links.shareToken = nil }) { link in
            LinkedTripSheet(link: link) { addLinked(link) }
                .presentationDetents([.medium])
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .padding(.horizontal, 20).padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(4)); self.toast = nil }
            }
        }
        .animation(.spring(duration: 0.35), value: toast)
    }
}

extension BackendClient.LinkedTrip: Identifiable { var id: String { flight.id } }

/// The card a shared link opens: the flight, who shared it, one button to take it.
struct LinkedTripSheet: View {
    let link: BackendClient.LinkedTrip
    let onAdd: () -> Void

    var body: some View {
        let f = link.flight
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(f.flightNumber).font(.title2.bold())
                Text(f.airlineName).foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading) {
                    Text(f.departure).font(.largeTitle.bold())
                    Text(f.departureAirport?.city ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.tint)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(f.arrival).font(.largeTitle.bold())
                    Text(f.arrivalAirport?.city ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(f.departureDay) · \(f.departureTime.clock) → \(f.arrivalTime.clock)")
            HStack(spacing: 8) {
                Circle().fill(link.owner.tint).frame(width: 22, height: 22)
                    .overlay(Text(link.ownerName.prefix(1).uppercased()).font(.caption2.bold()).foregroundStyle(.white))
                Text("Shared by \(link.ownerName)").foregroundStyle(link.owner.tint).fontWeight(.medium)
            }
            Button(action: onAdd) {
                Text("Add to trips").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 6)
        }
        .padding(24)
    }
}

extension String: @retroactive Identifiable { public var id: String { self } }
