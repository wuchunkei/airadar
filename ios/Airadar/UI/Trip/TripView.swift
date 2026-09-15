import SwiftUI

/// The trip list, one of two: the present (Now and Coming) under the Trip tab,
/// the past under its own. Pull to refresh; tapping the tab again scrolls to the top.
struct TripView: View {
    enum Scope { case present, past }

    var scope: Scope = .present
    let resetSignal: Int
    let canShare: Bool
    let onDeleted: (Flight) -> Void

    @EnvironmentObject private var store: FlightStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var settings: SettingsModel

    @State private var selectedId: String?
    /// Ticks every minute so the "Coming 22H" headings count down.
    @State private var clock = Date()
    @State private var shareFor: Flight?
    @State private var showFriends = false
    @State private var trackStatus: [String: TrackStatus] = [:]
    /// A manual trip being edited — swiped to from its card.
    @State private var editingFlight: Flight?

    // Newest first — the store itself keeps everyone sorted soonest-departure-first,
    // which is right for what's still coming but backwards for what's already flown.
    private var past: [Flight] { store.flights.filter { $0.phase == .past }.sorted { ($0.departureInstant ?? .distantPast) > ($1.departureInstant ?? .distantPast) } }
    private var airborne: [Flight] { store.flights.filter { $0.phase == .inProgress } }
    private var coming: [Flight] { store.flights.filter { $0.phase == .upcoming } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                // A List, because swipe-to-delete is the platform's own row gesture.
                List {
                    Group {
                        Color.clear.frame(height: 1).id("top")

                        if scope == .past {
                            SectionTitle("Past")
                            cards(past, dimmed: true, headings: true)
                            if past.isEmpty {
                                Text("No past trips yet.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 6)
                            }
                        } else {
                            // Now: in the air or leaving within three hours. Within a day: each under
                            // "Coming 22H", the whole hours left. Beyond that: "Coming", by date.
                            let hoursLeft: (Flight) -> Double = { f in
                                (f.departureInstant ?? .distantFuture).timeIntervalSince(clock) / 3600
                            }
                            let now = airborne + coming.filter { hoursLeft($0) <= 3 }
                            let soon = coming.filter { hoursLeft($0) > 3 && hoursLeft($0) <= 24 }
                            let later = coming.filter { hoursLeft($0) > 24 }
                            if !now.isEmpty {
                                SectionTitle("Now")
                                cards(now, dimmed: false, headings: false)
                            }
                            ForEach(soon) { f in
                                SectionTitle("In \(Int(hoursLeft(f).rounded(.down)))h")
                                cards([f], dimmed: false, headings: false)
                            }
                            if !later.isEmpty || (now.isEmpty && soon.isEmpty) {
                                if !now.isEmpty || !soon.isEmpty { Divider().padding(.top, 10).padding(.bottom, 4) }
                                SectionTitle("Coming")
                                cards(later, dimmed: false, headings: true)
                            }
                        }
                        if scope == .present {
                            if coming.isEmpty && airborne.isEmpty {
                                if past.isEmpty {
                                    // Nothing at all yet: one line, mid-screen, that opens Search.
                                    EmptyInvite()
                                } else {
                                    Text("No upcoming trips.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 6).padding(.bottom, 16)
                                }
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                .listStyle(.plain)
                // Rows are as tall as their content — the 44pt minimum would pad every heading.
                .environment(\.defaultMinListRowHeight, 1)
                .scrollContentBackground(.hidden)
                .refreshable { await store.refresh() }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        clock = Date()
                    }
                }
                .onChange(of: resetSignal) { withAnimation { proxy.scrollTo("top", anchor: .top) } }
            }
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                // Friends, where My keeps Settings: top right — plan holders only.
                if canShare {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showFriends = true } label: { Image(systemName: "person.2") }
                    }
                }
            }
            .navigationDestination(isPresented: $showFriends) { FriendsView() }
        }
        .sheet(item: $selectedId) { id in
            // Looked up by id so the sheet sees the refreshed Flight once a track is stored on it.
            if let flight = store.flights.first(where: { $0.id == id }) { detailSheet(flight) }
        }
        .background {
            // The share flow presents its own sheets; it just needs to exist while sharing.
            if let f = shareFor { ShareFlow(flight: f) { shareFor = nil } }
        }
        .sheet(item: $editingFlight) { flight in
            ManualFlightForm(editing: flight) { updated in
                store.replace(flight, with: updated)
                editingFlight = nil
            }
        }
    }

    @ViewBuilder
    private func cards(_ list: [Flight], dimmed: Bool, headings: Bool) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, flight in
            if headings, index == 0 || list[index - 1].departureDay != flight.departureDay {
                DateTitle(flight.departureDay, dimmed: dimmed)
            }
            FlightCard(flight: flight, forceSystemZone: settings.forceSystemZone, dimmed: dimmed) { selectedId = flight.id }
                .padding(.vertical, 5)
                .swipeToDelete(onEdit: flight.isManual ? { editingFlight = flight } : nil) {
                    store.delete(flight.id)
                    onDeleted(flight)
                }
        }
    }

    @ViewBuilder
    private func detailSheet(_ flight: Flight) -> some View {
        if flight.isPending {
            PendingFlightSheet(flight: flight,
                               onConfirm: { store.confirm($0); FlightReminders.schedule($0); selectedId = nil },
                               onReplace: { old, new in store.replace(old, with: new); FlightReminders.schedule(new); selectedId = nil },
                               onDismiss: { selectedId = nil })
        } else {
            FlightDetailSheet(
                flight: flight,
                forceSystemZone: settings.forceSystemZone,
                trackStatus: trackStatus[flight.id],
                onLoadTrack: { loadTrack(flight) },
                onDismiss: { selectedId = nil },
                extraActions: {
                    if let share = flight.sharedBy, share.status != .together {
                        RespondButtons(status: share.status) { action in
                            selectedId = nil
                            Task { try? await store.respondToShare(flight, action: action) }
                            if action != "reject" { FlightReminders.schedule(flight) }
                        }
                    } else if canShare, !flight.isPending {
                        Button { shareFor = flight } label: {
                            Label("Share", systemImage: "square.and.arrow.up").fontWeight(.semibold)
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                    }
                }
            )
        }
    }

    private func loadTrack(_ flight: Flight) {
        trackStatus[flight.id] = .loading
        Task {
            do {
                let fetched = try await OpenSkyClient.shared.fetchTrack(flight)
                store.setTrack(flight.id, points: fetched.points, flownOn: fetched.flownOn, icao24: fetched.icao24)
                trackStatus[flight.id] = .loaded
            } catch {
                trackStatus[flight.id] = .failed(error.localizedDescription)
            }
        }
    }
}

enum TrackStatus: Equatable {
    case loading, loaded, failed(String)
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.title.bold()).padding(.top, 6).padding(.bottom, 2) }
}

/// A day's heading over its cards: the section title's shape, at a smaller size.
struct DateTitle: View {
    let text: String
    let dimmed: Bool
    init(_ text: String, dimmed: Bool) { self.text = text; self.dimmed = dimmed }
    var body: some View {
        Text(text).font(.headline).foregroundStyle(dimmed ? .secondary : .primary).padding(.top, 8).padding(.bottom, 2)
    }
}

private struct EmptyInvite: View {
    var body: some View {
        // The tab switch is done by the search tab itself: this just says where to go.
        Text("Come to create your first trip!")
            .font(.headline).foregroundStyle(.tint)
            .frame(maxWidth: .infinity, minHeight: 360)
    }
}

/// Accept (green) · Together (yellow) · Reject (red); an accepted trip can still be taken together.
struct RespondButtons: View {
    let status: ShareStatus
    let onRespond: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if status == .pending {
                button("Accept", "accept", ShareStatus.accepted.blockColor, .white)
            }
            if status != .together {
                button("Together", "together", ShareStatus.together.blockColor, Color(white: 0.07))
            }
            if status == .pending {
                button("Reject", "reject", ShareStatus.rejected.blockColor, .white)
            }
        }
    }

    private func button(_ title: String, _ action: String, _ bg: Color, _ fg: Color) -> some View {
        Button { onRespond(action) } label: {
            Text(title).fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .buttonStyle(.glass)
        .tint(bg)
        .foregroundStyle(fg)
    }
}

extension View {
    /// Drag left to uncover Delete — the platform's own gesture, not a full-swipe dismiss.
    /// A manual trip also gets Edit beside it — there's nothing to edit on one
    /// a real source keeps in sync, so `onEdit` is only ever passed for those.
    func swipeToDelete(onEdit: (() -> Void)? = nil, onDelete: @escaping () -> Void) -> some View {
        self.swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            if let onEdit {
                Button(action: onEdit) { Label("Edit", systemImage: "pencil") }.tint(.orange)
            }
        }
    }
}
