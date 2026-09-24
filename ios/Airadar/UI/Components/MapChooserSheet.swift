import SwiftUI

/// Bottom sheet for picking which installed map app gives directions to the
/// departure airport.
struct MapChooserSheet: View {
    let airport: Airport
    @Environment(\.dismiss) private var dismiss

    private let providers = MapProvider.available

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Navigate to \(airport.iata)").font(.title3.weight(.semibold))
                Text(airport.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    Button {
                        provider.open(to: airport)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: provider.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(provider.tint, in: .rect(cornerRadius: 9, style: .continuous))
                            Text(provider.label).font(.body).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if index < providers.count - 1 { Divider().padding(.leading, 64) }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(118 + CGFloat(providers.count) * 59)])
        .presentationDragIndicator(.visible)
    }
}

private extension MapProvider {
    var symbol: String {
        switch self {
        case .apple: "map.fill"
        case .google: "location.fill"
        case .amap: "car.fill"
        }
    }

    var tint: Color {
        switch self {
        case .apple: .green
        case .google: .blue
        case .amap: .orange
        }
    }
}
