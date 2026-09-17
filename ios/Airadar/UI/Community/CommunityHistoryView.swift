import SwiftUI

/// My Reviews (default): every flight I've voted on, with the live tally
/// and how I voted. My Submissions: every flight I've fed that went to
/// community review, with the live tally and its current status. Both are
/// read-only — CommunityReviewCard with no vote handler.
struct CommunityHistoryView: View {
    private enum Mode: String, CaseIterable { case reviews = "My Reviews", submissions = "My Submissions" }

    @State private var mode: Mode = .reviews
    @State private var reviews: [CommunityReview] = []
    @State private var submissions: [CommunityReview] = []
    @State private var loading = true
    @State private var error: String?

    private var shown: [CommunityReview] { mode == .reviews ? reviews : submissions }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                ContentUnavailableView(mode == .reviews ? "You haven't reviewed anything yet." : "You haven't fed any flights yet.",
                                       systemImage: "tray")
            } else {
                List {
                    ForEach(shown) { review in
                        CommunityReviewCard(review: review)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .alert("Couldn't load", isPresented: .constant(error != nil), presenting: error) { _ in
            Button("OK") { error = nil }
        } message: { Text($0) }
    }

    private func load() async {
        do {
            async let r = BackendClient.communityHistoryReviews()
            async let s = BackendClient.communityHistorySubmissions()
            (reviews, submissions) = try await (r, s)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
