import SwiftUI
import MapKit

/// A lightweight, always-on route line for a list row: the same bowed arc the
/// real map draws, rendered as a small vector shape rather than a live MKMapView.
/// A card list can run to dozens of rows, and every one gets this — no network
/// snapshot to wait on, no map tiles to keep alive offscreen, no zoom to offer.
struct RouteThumbnail: View {
    let from: Airport?
    let to: Airport?
    var height: CGFloat = 52

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill))
            if let from, let to {
                RouteArc(from: from, to: to)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                Endpoints(from: from, to: to)
            } else {
                // Route not resolved yet (an airport code the database hasn't learnt) —
                // a neutral placeholder rather than an empty box.
                Image(systemName: "airplane").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 10))
    }
}

/// The two airports as small dots, at the same points the arc is fitted to.
private struct Endpoints: View {
    let from: Airport, to: Airport
    var body: some View {
        GeometryReader { g in
            let pts = RouteArc.fitted(from: from, to: to, in: g.size)
            if let first = pts.first, let last = pts.last {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5).position(first)
                Circle().fill(Color.accentColor).frame(width: 5, height: 5).position(last)
            }
        }
    }
}

/// The bowed route between two airports, projected flat and fitted (aspect kept,
/// centred) into whatever rect it is drawn in — the decorative-scale version of
/// the curve `TileMapView.arcPath` projects onto the real map.
private struct RouteArc: Shape {
    let from: Airport, to: Airport

    func path(in rect: CGRect) -> Path {
        let pts = Self.fitted(from: from, to: to, in: rect.size)
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        return path
    }

    static func fitted(from: Airport, to: Airport, in size: CGSize, insetBy inset: CGFloat = 8) -> [CGPoint] {
        let mapPts = TileMapView.arcPath(from, to).map { MKMapPoint($0) }
        guard let minX = mapPts.map(\.x).min(), let maxX = mapPts.map(\.x).max(),
              let minY = mapPts.map(\.y).min(), let maxY = mapPts.map(\.y).max(),
              size.width > 0, size.height > 0 else { return [] }
        // Map points run x east, y south — exactly the way SwiftUI's own x/y grow,
        // so no axis flip is needed to keep north pointing up.
        let spanX = max(maxX - minX, 1), spanY = max(maxY - minY, 1)
        let avail = CGSize(width: max(size.width - inset * 2, 1), height: max(size.height - inset * 2, 1))
        let scale = min(avail.width / CGFloat(spanX), avail.height / CGFloat(spanY))
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        let cx = size.width / 2, cy = size.height / 2
        return mapPts.map { p in
            CGPoint(x: cx + CGFloat(p.x - midX) * scale, y: cy + CGFloat(p.y - midY) * scale)
        }
    }
}
