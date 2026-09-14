import SwiftUI
import MapKit

struct MapRoute: Hashable { let from: Airport; let to: Airport; let weight: Int }
struct MapTrack: Hashable { let from: Airport; let to: Airport; let points: [TrackPoint] }

extension Array where Element == Flight {
    /// Distinct legs, weighted by how often they were flown.
    func toMapRoutes() -> [MapRoute] {
        var counts: [String: (Airport, Airport, Int)] = [:]
        for f in self {
            guard let a = f.departureAirport, let b = f.arrivalAirport else { continue }
            let key = "\(a.iata)-\(b.iata)"
            counts[key] = (a, b, (counts[key]?.2 ?? 0) + 1)
        }
        return counts.values.map { MapRoute(from: $0.0, to: $0.1, weight: $0.2) }
    }
}

/// OpenStreetMap standard tiles on an MKMapView — the same map as Android — with
/// great-circle routes, flown tracks, a midpoint arrow on each, and a tap that picks
/// the single nearest leg.
struct TileMapView: UIViewRepresentable {
    var routes: [MapRoute]
    var tracks: [MapTrack] = []
    var interactive = true
    var selected: [(Airport, Airport)] = []
    var emptyFocus: Region? = nil
    var onLegTap: (([(Airport, Airport)]) -> Void)? = nil
    var onMapTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isZoomEnabled = interactive
        map.isScrollEnabled = interactive
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        // OSM's standard style, whatever the app theme; Apple's own map stays hidden beneath.
        let osm = MKTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        osm.canReplaceMapContent = true
        osm.maximumZ = 18
        map.addOverlay(osm, level: .aboveLabels)
        // Nothing past the poles, and never so far out that the world is shorter than the screen.
        map.setCameraZoomRange(MKMapView.CameraZoomRange(minCenterCoordinateDistance: 500, maxCenterCoordinateDistance: 40_000_000), animated: false)
        if interactive {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
            map.addGestureRecognizer(tap)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        // Redraw the legs; keep the OSM overlay.
        map.removeOverlays(map.overlays.filter { !($0 is MKTileOverlay) })
        map.removeAnnotations(map.annotations)
        var legs: [Coordinator.Leg] = []

        for r in routes {
            let coords = greatCirclePath(r.from, r.to)
            let line = LegPolyline(coordinates: coords, count: coords.count)
            line.color = isSelected(r.from, r.to) ? Coordinator.selectedColor : Coordinator.routeColor
            line.width = min(3 + CGFloat(r.weight), 9)
            map.addOverlay(line, level: .aboveLabels)
            legs.append(.init(line: line, from: r.from, to: r.to))
        }
        for t in tracks {
            let coords = t.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let line = LegPolyline(coordinates: coords, count: coords.count)
            line.color = isSelected(t.from, t.to) ? Coordinator.selectedColor : Coordinator.routeColor
            line.width = 4
            map.addOverlay(line, level: .aboveLabels)
            legs.append(.init(line: line, from: t.from, to: t.to))
        }
        context.coordinator.legs = legs

        var airports: [String: Airport] = [:]
        for r in routes { airports[r.from.iata] = r.from; airports[r.to.iata] = r.to }
        for t in tracks { airports[t.from.iata] = t.from; airports[t.to.iata] = t.to }
        for a in airports.values {
            let pin = AirportAnnotation(airport: a)
            map.addAnnotation(pin)
        }

        // Frame the network once per set of legs, so a later redraw does not yank the
        // map out from under a pinch the traveller just made.
        let key = routes.hashValue &* 31 &+ tracks.hashValue
        if routes.isEmpty && tracks.isEmpty {
            if let focus = emptyFocus, context.coordinator.framedFor != focus.latitude.hashValue {
                context.coordinator.framedFor = focus.latitude.hashValue
                let span = MKCoordinateSpan(latitudeDelta: focus.spanDegrees, longitudeDelta: focus.spanDegrees)
                map.setRegion(MKCoordinateRegion(center: .init(latitude: focus.latitude, longitude: focus.longitude), span: span), animated: false)
            }
        } else if context.coordinator.framedFor != key {
            context.coordinator.framedFor = key
            var rect = MKMapRect.null
            for o in map.overlays where !(o is MKTileOverlay) { rect = rect.union(o.boundingMapRect) }
            let pad = min(map.bounds.width, map.bounds.height) / 7
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: pad, left: pad, bottom: pad, right: pad), animated: false)
        }
    }

    private func isSelected(_ a: Airport, _ b: Airport) -> Bool {
        selected.contains { $0.0.iata == a.iata && $0.1.iata == b.iata }
    }

    private func greatCirclePath(_ a: Airport, _ b: Airport) -> [CLLocationCoordinate2D] {
        let steps = 64
        let rad: Double = Double.pi / 180
        let lat1: Double = a.latitude * rad, lon1: Double = a.longitude * rad
        let lat2: Double = b.latitude * rad, lon2: Double = b.longitude * rad
        let sLat: Double = sin((lat1 - lat2) / 2)
        let sLon: Double = sin((lon1 - lon2) / 2)
        let h: Double = sLat * sLat + cos(lat1) * cos(lat2) * sLon * sLon
        let d: Double = 2 * asin(sqrt(h))
        if d == 0 { return [a.coordinate, b.coordinate] }
        let sinD: Double = sin(d)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(steps + 1)
        for i in 0...steps {
            let f: Double = Double(i) / Double(steps)
            let A: Double = sin((1 - f) * d) / sinD
            let B: Double = sin(f * d) / sinD
            let x: Double = A * cos(lat1) * cos(lon1) + B * cos(lat2) * cos(lon2)
            let y: Double = A * cos(lat1) * sin(lon1) + B * cos(lat2) * sin(lon2)
            let z: Double = A * sin(lat1) + B * sin(lat2)
            let lat: Double = atan2(z, sqrt(x * x + y * y)) / rad
            let lon: Double = atan2(y, x) / rad
            out.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return out
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let routeColor = UIColor(red: 0.04, green: 0.44, blue: 0.83, alpha: 1)
        static let selectedColor = UIColor(red: 0.91, green: 0.35, blue: 0.05, alpha: 1)

        struct Leg { let line: LegPolyline; let from: Airport; let to: Airport }

        var parent: TileMapView
        var legs: [Leg] = []
        var framedFor = 0

        init(_ parent: TileMapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
            if let leg = overlay as? LegPolyline { return ArrowedPolylineRenderer(polyline: leg) }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is AirportAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "airport") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "airport")
            view.annotation = annotation
            view.image = Self.dot
            view.canShowCallout = false
            return view
        }

        /// A tap on an airport dot: every leg touching it.
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let a = (view.annotation as? AirportAnnotation)?.airport else { return }
            let touching = legs.filter { $0.from.iata == a.iata || $0.to.iata == a.iata }.map { ($0.from, $0.to) }
            if !touching.isEmpty { parent.onLegTap?(touching) }
            mapView.deselectAnnotation(view.annotation, animated: false)
        }

        /// A tap on the map: the single nearest leg within reach, measured in points.
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            let p = g.location(in: map)
            var best: (Leg, CGFloat)?
            for leg in legs {
                let pts = leg.line.points()
                var prev: CGPoint?
                var minD = CGFloat.greatestFiniteMagnitude
                for i in 0..<leg.line.pointCount {
                    let cur = map.convert(pts[i].coordinate, toPointTo: map)
                    if let prev { minD = min(minD, distance(p, prev, cur)) }
                    prev = cur
                }
                if best == nil || minD < best!.1 { best = (leg, minD) }
            }
            if let best, best.1 <= 28 { parent.onLegTap?([(best.0.from, best.0.to)]) }
            else { parent.onMapTap?() }
        }

        private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx: CGFloat = b.x - a.x, dy: CGFloat = b.y - a.y
            let l2: CGFloat = dx * dx + dy * dy
            var t: CGFloat = 0
            if l2 != 0 {
                let dot: CGFloat = (p.x - a.x) * dx + (p.y - a.y) * dy
                t = max(0, min(1, dot / l2))
            }
            let cx: CGFloat = a.x + t * dx
            let cy: CGFloat = a.y + t * dy
            return hypot(p.x - cx, p.y - cy)
        }

        static let dot: UIImage = {
            let size = CGSize(width: 12, height: 12)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor(red: 0.04, green: 0.31, blue: 0.59, alpha: 1).setFill()
                ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: 3, y: 3, width: 6, height: 6))
            }
        }()
    }
}

final class LegPolyline: MKPolyline {
    var color: UIColor = .systemBlue
    var width: CGFloat = 3
}

final class AirportAnnotation: NSObject, MKAnnotation {
    let airport: Airport
    var coordinate: CLLocationCoordinate2D { airport.coordinate }
    init(airport: Airport) { self.airport = airport }
}

extension Airport {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// The line plus one arrowhead at its midpoint, pointing the way the flight goes.
final class ArrowedPolylineRenderer: MKPolylineRenderer {
    override init(polyline: MKPolyline) {
        super.init(polyline: polyline)
        let leg = polyline as? LegPolyline
        strokeColor = leg?.color ?? .systemBlue
        lineWidth = leg?.width ?? 3
        lineJoin = .round
        lineCap = .round
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        super.draw(mapRect, zoomScale: zoomScale, in: context)
        guard let leg = polyline as? LegPolyline, leg.pointCount >= 2 else { return }
        let pts = leg.points()
        let mid = leg.pointCount / 2
        let a = point(for: pts[max(0, mid - 1)]), b = point(for: pts[min(leg.pointCount - 1, mid + 1)])
        let m = point(for: pts[mid])
        let angle: CGFloat = atan2(b.y - a.y, b.x - a.x)
        let size: CGFloat = 9 / zoomScale
        context.saveGState()
        context.translateBy(x: m.x, y: m.y)
        context.rotate(by: angle)
        context.setFillColor((leg.color).cgColor)
        context.move(to: CGPoint(x: size, y: 0))
        context.addLine(to: CGPoint(x: -size * 0.9, y: -size * 0.8))
        context.addLine(to: CGPoint(x: -size * 0.4, y: 0))
        context.addLine(to: CGPoint(x: -size * 0.9, y: size * 0.8))
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }
}
