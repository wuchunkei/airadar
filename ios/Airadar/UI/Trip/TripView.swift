import SwiftUI

/// The timeline: Past (hidden until an over-pull), Now, Coming. Pull to refresh;
/// pull further and let go to reveal the past; scroll the present back to the
/// top and the past folds away again. Tapping the Trip tab again resets.
struct TripView: View {
    let resetSignal: Int
    let canShare: Bool
    let onDeleted: (Flight) -> Void

    @EnvironmentObject private var store: FlightStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var settings: SettingsModel

    @State private var showHistory = false
    @State private var pull: CGFloat = 0
    @State private var refreshing = false
    @State private var selectedId: String?
    @State private var shareFor: Flight?
    @State private var showFriends = false
    @State private var trackStatus: [String: TrackStatus] = [:]

    private let refreshThreshold: CGFloat = 44
    private let historyThreshold: CGFloat = 84

    private var past: [Flight] { store.flights.filter { $0.phase == .past } }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { await store.refresh(); refreshing = false }
    }
    private var airborne: [Flight] { store.flights.filter { $0.phase == .inProgress } }
    private var coming: [Flight] { store.flights.filter { $0.phase == .upcoming } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                // A List, because swipe-to-delete is the platform's own row gesture.
                List {
                    Group {
                        // The past is always in the list, above the present; the fence on the
                        // heading row decides whether it can be reached.
                        if !past.isEmpty {
                            SectionTitle("Past")
                            cards(past, dimmed: true, headings: true)
                            Divider().padding(.top, 10).padding(.bottom, 4)
                        }

                        Color.clear.frame(height: 1).id("present")
                            .background(PresentFence(
                                open: showHistory, tail: 520,
                                onPull: { pull = $0 },
                                onRelease: { over in
                                    if over >= refreshThreshold { refresh() }
                                    if over >= historyThreshold, !past.isEmpty { showHistory = true }
                                },
                                onSettled: { showHistory = false }))

                        if !airborne.isEmpty {
                            SectionTitle("Now")
                            cards(airborne, dimmed: false, headings: false)
                            Divider().padding(.top, 10).padding(.bottom, 4)
                            SectionTitle("Coming")
                        } else {
                            // "Now" only when a flight departs today; otherwise what is ahead is "Coming".
                            let today = LocalDateTime.from(Date(), in: .current).dayString
                            SectionTitle(coming.contains { $0.departureDay == today } ? "Now" : "Coming")
                        }
                        cards(coming, dimmed: false, headings: true)

                        if coming.isEmpty && airborne.isEmpty {
                            if past.isEmpty {
                                // Nothing at all yet: one line, mid-screen, that opens Search.
                                EmptyInvite()
                            } else {
                                Text("No upcoming trips.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 6).padding(.bottom, 16)
                            }
                        }
                        // Room below a short present so the heading can always sit at the top;
                        // the fence discounts it when measuring where the content ends.
                        Color.clear.frame(height: 520)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                .listStyle(.plain)
                // Rows are as tall as their content — the 44pt minimum would pad every heading.
                .environment(\.defaultMinListRowHeight, 1)
                .scrollContentBackground(.hidden)
                // What the pull is about to do, then the refresh in progress — at the top, over the list.
                .overlay(alignment: .top) {
                    Group {
                        if refreshing {
                            ProgressView()
                        } else if !showHistory, pull >= refreshThreshold {
                            Text(pull >= historyThreshold && !past.isEmpty ? "Release for past trips" : "Release to refresh")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
                .onChange(of: resetSignal) { showHistory = false; proxy.scrollTo("present", anchor: .top) }
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
    }

    @ViewBuilder
    private func cards(_ list: [Flight], dimmed: Bool, headings: Bool) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, flight in
            if headings, index == 0 || list[index - 1].departureDay != flight.departureDay {
                DateTitle(flight.departureDay, dimmed: dimmed)
            }
            FlightCard(flight: flight, forceSystemZone: settings.forceSystemZone, dimmed: dimmed) { selectedId = flight.id }
                .padding(.vertical, 5)
                .swipeToDelete {
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
                store.setTrack(flight.id, points: fetched.points, flownOn: fetched.flownOn)
                trackStatus[flight.id] = .loaded
            } catch {
                trackStatus[flight.id] = .failed(error.localizedDescription)
            }
        }
    }
}

enum TrackStatus: Equatable { case loading, loaded, failed(String) }

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
    func swipeToDelete(_ action: @escaping () -> Void) -> some View {
        self.swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: action) { Label("Delete", systemImage: "trash") }
        }
    }
}
