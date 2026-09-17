import SwiftUI

/// A fed flight the automated scorer (backend/app/feed.py) couldn't settle
/// either way waits here for other travellers to vote real/not-real on —
/// never my own submissions, never one I've already voted on. History
/// (top right, where Friends sat on the old separate Past tab) is the only
/// toolbar item here; Community has no Friends button of its own.
struct CommunityView: View {
    @State private var reviews: [CommunityReview] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if reviews.isEmpty {
                    ContentUnavailableView("Nothing to review right now.", systemImage: "checkmark.circle")
                } else {
                    List {
                        ForEach(reviews) { review in
                            CommunityReviewCard(review: review) { approve in vote(review, approve: approve) }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Community")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
            .navigationDestination(isPresented: $showHistory) { CommunityHistoryView() }
            .refreshable { await load() }
            .task { await load() }
            .alert("Couldn't load", isPresented: .constant(error != nil), presenting: error) { _ in
                Button("OK") { error = nil }
            } message: { Text($0) }
        }
    }

    private func load() async {
        do {
            reviews = try await BackendClient.communityQueue()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func vote(_ review: CommunityReview, approve: Bool) {
        // Optimistic: gone from this queue the moment the tap lands, since
        // one vote per person is all this ever allows anyway.
        reviews.removeAll { $0.id == review.id }
        Task { try? await BackendClient.voteOnReview(review.id, approve: approve) }
    }
}

/// Flight facts (the same plain "code → code, clock → clock" a shared-link
/// preview already uses) plus a two-button footer and the live tally.
struct CommunityReviewCard: View {
    let review: CommunityReview
    /// nil hides the vote buttons — used read-only in History.
    var onVote: ((Bool) -> Void)? = nil

    private var tallyText: String {
        "\(review.approveCount) approve · \(review.rejectCount) reject"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(review.airlineName.isEmpty ? "—" : review.airlineName).font(.subheadline.weight(.medium))
                Spacer()
                Text(review.flightNumber).font(.subheadline.bold()).foregroundStyle(.tint)
            }
            HStack {
                VStack(alignment: .leading) {
                    Text(review.departure).font(.title3.bold())
                    Text(review.departureAirport?.city ?? "").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(.tint)
                VStack(alignment: .trailing) {
                    Text(review.arrival).font(.title3.bold())
                    Text(review.arrivalAirport?.city ?? "").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text("\(review.departureTime.dayString) · \(review.departureTime.clock) → \(review.arrivalTime.clock)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(tallyText).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if review.boosted { Text("· needs more votes").font(.caption).foregroundStyle(.orange) }
                Spacer()
                if let vote = review.myVote {
                    Text(vote ? "You: Approved" : "You: Rejected").font(.caption.weight(.semibold)).foregroundStyle(vote ? .green : .red)
                }
            }
            if let onVote {
                HStack(spacing: 10) {
                    Button { onVote(true) } label: {
                        Label("Looks real", systemImage: "checkmark").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glass).tint(.green)
                    Button { onVote(false) } label: {
                        Label("Doesn't look real", systemImage: "xmark").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glass).tint(.red)
                }
            } else {
                StatusPill(status: review.status)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Pending (secondary) / Confirmed (green) / Rejected (red) / Expired (orange).
struct StatusPill: View {
    let status: String
    private var color: Color {
        switch status {
        case "confirmed": .green
        case "rejected": .red
        case "expired": .orange
        default: .secondary
        }
    }
    var body: some View {
        Text(status.capitalized).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: .rect(cornerRadius: 6))
    }
}
