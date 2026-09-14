import SwiftUI
import MapKit
import LinkPresentation

/// The picture handed to the iOS share sheet: the route on a map, the flight
/// underneath — what a traveller sends to someone who has no Airadar.
@MainActor
enum ShareImage {
    static func render(_ flight: Flight, forceSystemZone: Bool) async -> UIImage? {
        let map = await mapSnapshot(flight)
        let renderer = ImageRenderer(content: ShareCardView(flight: flight, map: map, forceSystemZone: forceSystemZone))
        renderer.scale = 3
        renderer.proposedSize = .init(width: 390, height: nil)
        return renderer.uiImage
    }

    /// A temporary PNG named after the flight, so the sheet shows "CX310 2026-09-20" rather than a number.
    static func file(_ image: UIImage, for flight: Flight) -> URL? {
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(flight.flightNumber) \(flight.departureDay).png")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Apple Maps with the great-circle route and both airports drawn on.
    private static func mapSnapshot(_ flight: Flight) async -> UIImage? {
        guard let from = flight.departureAirport, let to = flight.arrivalAirport else { return nil }
        let path = TileMapView.greatCirclePath(from, to)
        let line = MKPolyline(coordinates: path, count: path.count)
        var rect = line.boundingMapRect
        let pad = max(rect.width, rect.height) * 0.25 + 50_000
        rect = rect.insetBy(dx: -pad, dy: -pad)

        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = CGSize(width: 390, height: 400)
        options.scale = 3
        options.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        guard let snap = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: options.size, format: format).image { ctx in
            snap.image.draw(at: .zero)
            let cg = ctx.cgContext
            cg.setStrokeColor(TileMapView.Coordinator.routeColor.cgColor)
            cg.setLineWidth(3)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            let points = path.map { snap.point(for: $0) }
            cg.addLines(between: points)
            cg.strokePath()
            for a in [from, to] {
                let p = snap.point(for: a.coordinate)
                let dot = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
                cg.setFillColor(UIColor.white.cgColor); cg.fillEllipse(in: dot)
                cg.setFillColor(TileMapView.Coordinator.routeColor.cgColor); cg.fillEllipse(in: dot.insetBy(dx: 3, dy: 3))
            }
        }
    }
}

/// Map on top, the flight below; fixed light look so it reads the same wherever it lands.
private struct ShareCardView: View {
    let flight: Flight
    let map: UIImage?
    let forceSystemZone: Bool

    var body: some View {
        let dep = flight.shownTime(arrival: false, forceSystemZone: forceSystemZone)
        let arr = flight.shownTime(arrival: true, forceSystemZone: forceSystemZone)
        VStack(spacing: 0) {
            Group {
                if let map { Image(uiImage: map).resizable().scaledToFill() }
                else { Color(white: 0.9) }
            }
            .frame(width: 390, height: 400).clipped()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(flight.flightNumber).font(.title2.bold().monospaced())
                    Text(flight.airlineName).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(flight.departureDay).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    endpoint(code: flight.departure, city: flight.departureAirport?.cityCountry, time: dep, alignment: .leading)
                    Spacer()
                    Image(systemName: "airplane").font(.title3).foregroundStyle(.secondary).padding(.top, 10)
                    Spacer()
                    endpoint(code: flight.arrival, city: flight.arrivalAirport?.cityCountry, time: arr, alignment: .trailing)
                }
                HStack {
                    Image(systemName: "airplane.circle.fill")
                    Text("Airadar").fontWeight(.semibold)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(width: 390)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func endpoint(code: String, city: String?, time: ShownTime, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(code).font(.system(size: 34, weight: .bold, design: .rounded))
            if let city { Text(city).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 4) {
                Text(time.clock).font(.headline.monospacedDigit())
                Text(time.zone).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.black)
    }
}

/// The words that go with the picture: an itinerary in the shape the mail import
/// recognises — flight code and ISO date on their own lines — with the link at the
/// end. Sent as an email, Airadar on the other side files the trip by itself.
@MainActor
final class ShareText: NSObject, UIActivityItemSource {
    let flight: Flight
    let link: URL?
    let forceSystemZone: Bool
    let icon: UIImage?

    init(flight: Flight, link: URL?, forceSystemZone: Bool, icon: UIImage?) {
        self.flight = flight; self.link = link; self.forceSystemZone = forceSystemZone; self.icon = icon
    }

    var subject: String { "Flight \(flight.flightNumber) on \(flight.departureDay) · Airadar itinerary" }

    var body: String {
        let dep = flight.shownTime(arrival: false, forceSystemZone: forceSystemZone)
        let arr = flight.shownTime(arrival: true, forceSystemZone: forceSystemZone)
        // Airport codes are three letters and cities are spelt out, so nothing here
        // reads as a second flight number to the parser.
        func place(_ a: Airport?, _ code: String, _ terminal: String?) -> String {
            var s = a.map { "\($0.city) (\(code))" } ?? code
            if let terminal { s += ", Terminal \(terminal)" }
            return s
        }
        var lines = [
            "Airadar itinerary",
            "",
            "Flight \(flight.flightNumber) · \(flight.airlineName)",
            "Date: \(flight.departureDay)",
            "Departure: \(place(flight.departureAirport, flight.departure, flight.departureTerminal)) \(dep.clock) \(dep.zone)",
            "Arrival: \(place(flight.arrivalAirport, flight.arrival, flight.arrivalTerminal)) \(arr.clock) \(arr.zone)",
        ]
        if let link {
            lines += ["", "Open in Airadar: \(link.absoluteString)"]
        }
        lines += ["", "If Airadar reads your mailbox, this email adds the trip on its own."]
        return lines.joined(separator: "\n")
    }

    func activityViewControllerPlaceholderItem(_ vc: UIActivityViewController) -> Any { body }
    func activityViewController(_ vc: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? { body }
    func activityViewController(_ vc: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String { subject }

    func activityViewControllerLinkMetadata(_ vc: UIActivityViewController) -> LPLinkMetadata? {
        let meta = LPLinkMetadata()
        meta.title = "\(flight.flightNumber) \(flight.departure) → \(flight.arrival) · \(flight.departureDay)"
        meta.originalURL = link
        meta.url = link
        if let icon { meta.iconProvider = NSItemProvider(object: icon) }
        return meta
    }
}
