import SwiftUI

/// Bottom sheet for picking which installed map app gives directions to the
/// departure airport.
struct MapChooserSheet: View {
    let airport: Airport
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 0

    private let providers = MapProvider.available

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Navigate to \(airport.iata)").font(.title3.weight(.semibold))
                Text(airport.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 0) {
                ForEach(providers) { provider in
                    Button {
                        provider.open(to: airport)
                        dismiss()
                    } label: {
                        Text(provider.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if provider != providers.last { Divider().padding(.leading, 16) }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.custom(MapChooserSheetDetent.self)])
        .presentationDragIndicator(.visible)
        .background(SheetDetentRefresher<MapChooserSheetDetent>(height: height))
    }
}
