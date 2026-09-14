import SwiftUI

/// Share, the way the traveller asked: with friends, a row of them to pick from,
/// the leftmost being "other ways" (the iOS share sheet, link included); with no
/// friends, straight to the iOS share sheet.
struct ShareFlow: View {
    let flight: Flight
    let onDone: () -> Void
    @EnvironmentObject private var store: FlightStore
    @EnvironmentObject private var settings: SettingsModel

    @State private var friends: [Friend]?
    @State private var chosen: Set<String> = []
    @State private var shareItems: ShareItems?
    @State private var preparing = false
    @State private var note: String?
    @State private var showPicker = false

    var body: some View {
        Color.clear
            .task {
                let list = ((try? await BackendClient.friends()) ?? []).filter { $0.status == .accepted }
                friends = list
                if list.isEmpty { await openSystemShare() } else { showPicker = true }
            }
            .sheet(isPresented: $showPicker, onDismiss: onDone) { picker.presentationDetents([.height(260)]) }
            .sheet(item: $shareItems, onDismiss: { if friends?.isEmpty ?? true { onDone() } }) { items in
                ActivityView(items: items.items)
            }
            .overlay { if preparing { ProgressView().padding(24).glassEffect(.regular, in: .rect(cornerRadius: 16)) } }
    }

    /// What the system sheet gets: a picture of the trip first, the link beside it.
    private struct ShareItems: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share \(flight.flightNumber)").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    // Leftmost: every other way, through the system share sheet.
                    Button { Task { await openSystemShare() } } label: {
                        VStack(spacing: 6) {
                            Circle().fill(Color(.secondarySystemBackground)).frame(width: 56, height: 56)
                                .overlay(Image(systemName: "square.and.arrow.up").font(.title3))
                            Text("Other").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(friends ?? []) { f in
                        let status = flight.shares.first { $0.person.id == f.person.id }?.status
                        let picked = chosen.contains(f.person.id)
                        Button { if status == nil { toggle(f.person.id) } } label: {
                            VStack(spacing: 6) {
                                Circle().fill(f.person.tint).frame(width: 56, height: 56)
                                    .overlay {
                                        if picked { Image(systemName: "checkmark").font(.title3.bold()).foregroundStyle(.white) }
                                        else { Text(f.person.givenName.prefix(1).uppercased()).font(.title3.bold()).foregroundStyle(.white) }
                                    }
                                    .overlay { if picked { Circle().strokeBorder(.primary, lineWidth: 2) } }
                                Text(status?.label ?? f.person.givenName).font(.caption).foregroundStyle(status?.blockColor ?? f.person.tint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
            Button { send() } label: {
                Text(chosen.count <= 1 ? "Send to friend" : "Send to \(chosen.count) friends")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent).disabled(chosen.isEmpty)
            if let note { Text(note).font(.caption).foregroundStyle(.red) }
        }
        .padding(20)
    }

    private func toggle(_ id: String) { if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) } }

    private func send() {
        let picked = (friends ?? []).filter { chosen.contains($0.person.id) }.map(\.person)
        Task {
            for p in picked { try? await store.share(flight, with: p) }
            showPicker = false
        }
    }

    @MainActor
    private func openSystemShare() async {
        preparing = true
        defer { preparing = false }
        // The link first: the picture carries it as a QR code.
        let url = (try? await BackendClient.shareTrip(flight.id).url).flatMap { URL(string: $0) }
        let image = await ShareImage.render(flight, link: url, forceSystemZone: settings.forceSystemZone)
        // The itinerary text (link inside, ready to be an email) and the picture.
        var items: [Any] = [ShareText(flight: flight, link: url, forceSystemZone: settings.forceSystemZone, icon: image)]
        if let image, let file = ShareImage.file(image, for: flight) { items.append(file) }
        guard url != nil || image != nil else {
            note = "Could not prepare the share."
            if friends?.isEmpty ?? true { onDone() }
            return
        }
        showPicker = false
        shareItems = ShareItems(items: items)
    }
}
