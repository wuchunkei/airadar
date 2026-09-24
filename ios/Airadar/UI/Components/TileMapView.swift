import SwiftUI
import MapKit

/// One flight's leg. `rank` counts earlier flights in the same direction between
/// the same two airports: each repeat bows a little further out, so none overlap.
/// `isReturn` marks the direction opposite to the pair's first flight; it bows to
/// the other side of the line between the two, mirroring the outbound arcs.
struct MapRoute: Hashable {
    let from: Airport; let to: Airport; let rank: Int; let isReturn: Bool
    /// Set while the flight is in the air with no real track: the share of the way
    /// flown by the clock. The arc is then dashed, the flown part green, a plane at the point.
    var progress: Double? = nil
}
struct MapTrack: Hashable {
    let from: Airport; let to: Airport; let points: [TrackPoint]
    /// Still flying: the track is drawn green with the plane at its end.
    var live: Bool = false
    /// Expected landing, delay included, and the minute this is drawn for: with
    /// both, a live track whose last real fix has gone stale (out of receiver
    /// range over the sea, say) gets the plane moved on to where it should be by now.
    var eta: Date? = nil
    var now: Date? = nil

    /// Where the plane should be by `now`, along the way from its last real fix
    /// to the destination, in proportion to the time from that fix to `eta`.
    /// Nil while the last fix is still fresh (under ten minutes old).
    var estimatedPosition: CLLocationCoordinate2D? {
        guard live, let now, let eta, let last = points.last, let seen = last.time,
              now.timeIntervalSince(seen) > 600, eta > seen else { return nil }
        let fraction = min(0.97, now.timeIntervalSince(seen) / eta.timeIntervalSince(seen))
        let path = TileMapView.arcPath(from: CLLocationCoordinate2D(latitude: last.lat, longitude: last.lon), to: to.coordinate)
        return path[Int(Double(path.count - 1) * fraction)]
    }
}

extension Array where Element == Flight {
    /// A leg per flight, oldest first, ranked among its repeats.
    func toMapRoutes() -> [MapRoute] {
        var seen: [String: Int] = [:]
        var firstFrom: [String: String] = [:]
        var out: [MapRoute] = []
        for f in self.sorted(by: { ($0.departureInstant ?? .distantPast) < ($1.departureInstant ?? .distantPast) }) {
            guard let a = f.departureAirport, let b = f.arrivalAirport else { continue }
            let pair = [a.iata, b.iata].sorted().joined(separator: "-")
            let way = "\(a.iata)>\(b.iata)"
            let rank = seen[way] ?? 0
            seen[way] = rank + 1
            if firstFrom[pair] == nil { firstFrom[pair] = a.iata }
            out.append(MapRoute(from: a, to: b, rank: rank, isReturn: firstFrom[pair] != a.iata,
                                progress: f.phase == .inProgress ? f.fractionFlown : nil))
        }
        return out
    }
}

/// Apple Maps (the platform's own) with bowed routes, flown tracks, a
/// midpoint arrow on each, and a tap that picks the single nearest leg.
struct TileMapView: UIViewRepresentable {
    var routes: [MapRoute]
    var tracks: [MapTrack] = []
    var interactive = true
    /// City names beside the airport dots — for the small preview, where the map's own labels are too sparse.
    var cityLabels = false
    /// Colour by compass direction instead of outbound/return — northbound blue,
    /// southbound green — for the "My" overview, where one line per leg reads
    /// better by which way it points than by which trip it belonged to.
    var directionColored = false
    /// Where the aircraft actually is (ADS-B); with it, the plane leaves the arc's estimate for the real point.
    var livePlane: LivePosition? = nil
    /// The one leg to highlight — (from, to, rank), naming the exact repeat of
    /// that pair a line tap picked out — or nil for none.
    var selected: (Airport, Airport, Int)? = nil
    /// An airport to show a dot for even with no route touching it — an upcoming
    /// departure, say — and whether to draw that dot blue (a route to it is
    /// actually available) or leave it the ordinary colour.
    struct HighlightedAirport: Equatable { let airport: Airport; let reachable: Bool }
    var highlightedAirports: [HighlightedAirport] = []
    /// The dot — off by default. On, `userTrackingMode` decides whether the
    /// camera actually follows it too.
    var showsUserLocation = false
    /// Two-way: `.follow` recentres the camera on the user each time a new fix
    /// comes in — a plain re-centre, not MapKit's own tracking-mode camera,
    /// which snaps to a close, street-level zoom the moment it engages and
    /// would undo whatever zoom was showing the route network. A manual pan
    /// lets go of following, same as MapKit's own tracking mode would, so a
    /// button watching this binding still sees it demoted back to `.none`.
    var userTrackingMode: Binding<MKUserTrackingMode>? = nil
    var emptyFocus: Region? = nil
    /// However much of the bottom is covered by cards floating over the map
    /// — while following the user, the visual centre shifts up by half of
    /// this, so "my location" centres in the map that's actually free to
    /// look at, not behind whatever's overlaid at the bottom.
    var bottomInset: CGFloat = 0
    /// A tap on one line: which leg, exactly.
    var onLegTap: ((Airport, Airport, Int) -> Void)? = nil
    /// A tap on an airport's dot.
    var onAirportTap: ((Airport) -> Void)? = nil
    var onMapTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = SizedMapView()
        map.delegate = context.coordinator
        // Framing needs a real size; the first update usually comes before layout.
        map.onLaidOut = { [weak coordinator = context.coordinator] in coordinator?.frameIfPending() }
        map.isUserInteractionEnabled = interactive
        map.isZoomEnabled = interactive
        map.isScrollEnabled = interactive
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        // Nothing past the poles, and never so far out that the world is shorter than the screen.
        map.setCameraZoomRange(MKMapView.CameraZoomRange(minCenterCoordinateDistance: 500, maxCenterCoordinateDistance: 40_000_000), animated: false)
        if interactive {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
            map.addGestureRecognizer(tap)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self

        // A tap only ever changes `selected` — tearing down and rebuilding
        // every overlay and annotation for that (dozens of them, once a
        // traveller has any real history) is what visibly hitched. When
        // the network itself hasn't moved, just recolour the two lines
        // whose selection state actually changed.
        let networkUnchanged = context.coordinator.hasBuilt
            && routes == previous.routes && tracks == previous.tracks
            && highlightedAirports == previous.highlightedAirports
            && cityLabels == previous.cityLabels && directionColored == previous.directionColored
        if networkUnchanged {
            recolorSelection(map, context: context, previousSelected: previous.selected)
        } else {
            rebuildOverlays(map, context: context)
        }

        map.showsUserLocation = showsUserLocation
        let following = userTrackingMode?.wrappedValue == .follow || userTrackingMode?.wrappedValue == .followWithHeading
        context.coordinator.following = following
        // A plain re-centre on whatever fix is already in hand — never through
        // MapKit's own tracking-mode camera, which would zoom to street level
        // the instant it engaged and undo the zoom the route network needs.
        if following, let loc = map.userLocation.location {
            context.coordinator.recenter(map, on: loc.coordinate)
        }

        // Frame the network once per set of legs, so a later redraw does not yank the
        // map out from under a pinch the traveller just made — or, now, away from
        // wherever following has the camera locked onto the user instead.
        guard !following else { return }
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
            for o in map.overlays { rect = rect.union(o.boundingMapRect) }
            context.coordinator.pendingRect = rect
            context.coordinator.map = map
            context.coordinator.frameIfPending()
        }
    }

    private func isSelected(_ a: Airport, _ b: Airport, rank: Int) -> Bool {
        guard let selected else { return false }
        return selected.0.iata == a.iata && selected.1.iata == b.iata && selected.2 == rank
    }

    private func isSelected(_ leg: Coordinator.Leg, in candidate: (Airport, Airport, Int)?) -> Bool {
        guard let candidate else { return false }
        return candidate.0.iata == leg.from.iata && candidate.1.iata == leg.to.iata && candidate.2 == leg.rank
    }

    /// Only `selected` moved: recolour just the (at most two) lines whose
    /// highlight state actually flipped, and ask their existing renderers to
    /// redraw — never touches the overlay or annotation lists themselves.
    private func recolorSelection(_ map: MKMapView, context: Context, previousSelected: (Airport, Airport, Int)?) {
        for leg in context.coordinator.legs {
            let was = isSelected(leg, in: previousSelected)
            let now = isSelected(leg, in: selected)
            guard was != now else { continue }
            leg.line.color = now ? Coordinator.selectedColor : leg.baseColor
            if let renderer = map.renderer(for: leg.line) as? ArrowedPolylineRenderer {
                renderer.strokeColor = leg.line.color
                renderer.setNeedsDisplay()
            }
        }
    }

    /// The full teardown-and-redraw: every overlay and annotation, from
    /// scratch. Needed whenever the network itself changed — a new route
    /// appeared, a live position moved the in-flight plane, and so on.
    private func rebuildOverlays(_ map: MKMapView, context: Context) {
        context.coordinator.hasBuilt = true
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        var legs: [Coordinator.Leg] = []

        for r in routes {
            let coords = Self.arcPath(r.from, r.to, rank: r.rank)
            if let p = r.progress {
                // Whole way dashed; the part flown solid green; the plane at the point reached —
                // the real point when ADS-B has one (the arc is cut where it comes nearest), the
                // timetable's estimate otherwise.
                let dashedColor = UIColor.secondaryLabel.withAlphaComponent(0.6)
                let whole = LegPolyline(coordinates: coords, count: coords.count)
                whole.color = dashedColor; whole.width = 1.0; whole.dashed = true; whole.arrow = false
                map.addOverlay(whole, level: .aboveLabels)
                var n = max(2, Int(Double(coords.count - 1) * p) + 1)
                var planeAt = coords[n - 1]
                var heading = Self.bearing(coords[max(0, n - 2)], coords[n - 1])
                // A fix over ten minutes old is where it was, not where it is: past
                // that, the timetable's estimate is the better guess.
                if let live = livePlane, Date().timeIntervalSince(live.seenAt) < 600 {
                    let here = MKMapPoint(live.coordinate)
                    n = max(2, (coords.indices.min { MKMapPoint(coords[$0]).distance(to: here) < MKMapPoint(coords[$1]).distance(to: here) } ?? 1) + 1)
                    planeAt = live.coordinate
                    heading = live.heading
                }
                let flown = LegPolyline(coordinates: Array(coords.prefix(n)), count: n)
                flown.color = Coordinator.liveColor; flown.width = 1.6; flown.arrow = false
                map.addOverlay(flown, level: .aboveLabels)
                map.addAnnotation(PlaneAnnotation(coordinate: planeAt, heading: heading))
                legs.append(.init(line: whole, from: r.from, to: r.to, rank: r.rank, baseColor: dashedColor))
                continue
            }
            let line = LegPolyline(coordinates: coords, count: coords.count)
            let base = directionColored ? Coordinator.directionColor(r.from, r.to) : (r.isReturn ? Coordinator.returnColor : Coordinator.routeColor)
            line.color = isSelected(r.from, r.to, rank: r.rank) ? Coordinator.selectedColor : base
            line.width = 1.0
            map.addOverlay(line, level: .aboveLabels)
            legs.append(.init(line: line, from: r.from, to: r.to, rank: r.rank, baseColor: base))
        }
        for t in tracks {
            let coords = t.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let line = LegPolyline(coordinates: coords, count: coords.count)
            let base = t.live ? Coordinator.liveColor : Coordinator.routeColor
            line.color = isSelected(t.from, t.to, rank: 0) ? Coordinator.selectedColor : base
            line.width = t.live ? 1.6 : 1.2
            line.arrow = !t.live
            map.addOverlay(line, level: .aboveLabels)
            if t.live, coords.count >= 2 {
                var last = coords[coords.count - 1]
                var heading = Self.bearing(coords[coords.count - 2], last)
                if let estimate = t.estimatedPosition {
                    // Out of receiver range: dashed green from the last real fix to
                    // where it should be by now, so the estimate reads as one.
                    let gap = Self.arcPath(from: last, to: estimate)
                    let guess = LegPolyline(coordinates: gap, count: gap.count)
                    guess.color = Coordinator.liveColor; guess.width = 1.6; guess.dashed = true; guess.arrow = false
                    map.addOverlay(guess, level: .aboveLabels)
                    if gap.count >= 2 { heading = Self.bearing(gap[gap.count - 2], estimate) }
                    last = estimate
                }
                map.addAnnotation(PlaneAnnotation(coordinate: last, heading: heading))
                // The way still to go, dashed, so the map frames the whole flight and not just the bit flown.
                let rest = Self.arcPath(from: last, to: t.to.coordinate)
                let ahead = LegPolyline(coordinates: rest, count: rest.count)
                ahead.color = UIColor.secondaryLabel.withAlphaComponent(0.6); ahead.width = 1.0; ahead.dashed = true; ahead.arrow = false
                map.addOverlay(ahead, level: .aboveLabels)
            } else if let last = coords.last,
                      MKMapPoint(last).distance(to: MKMapPoint(t.to.coordinate)) > 50_000 {
                // A finished flight whose recorded track stops short (no receivers
                // along the rest of the way): the rest dashed to where it landed,
                // so it reads as unrecorded, not as a plane that vanished midway.
                let rest = Self.arcPath(from: last, to: t.to.coordinate)
                let gap = LegPolyline(coordinates: rest, count: rest.count)
                gap.color = base; gap.width = 1.0; gap.dashed = true; gap.arrow = false
                map.addOverlay(gap, level: .aboveLabels)
            }
            legs.append(.init(line: line, from: t.from, to: t.to, rank: 0, baseColor: base))
        }
        context.coordinator.legs = legs

        var airports: [String: Airport] = [:]
        for r in routes { airports[r.from.iata] = r.from; airports[r.to.iata] = r.to }
        for t in tracks { airports[t.from.iata] = t.from; airports[t.to.iata] = t.to }
        for h in highlightedAirports { airports[h.airport.iata] = h.airport }
        let blue = Set(highlightedAirports.filter(\.reachable).map { $0.airport.iata })
        for a in airports.values {
            let pin = AirportAnnotation(airport: a, label: cityLabels ? a.city : nil, blue: blue.contains(a.iata))
            map.addAnnotation(pin)
        }
    }

    /// The bowed line between two airports. The rule: every flight keeps to the
    /// RIGHT of its direction of travel — northbound bows east, southbound west,
    /// eastbound south, westbound north — so the way out and the way back sit on
    /// opposite sides of the line between the two airports, and every repeat in
    /// one direction steps a fixed amount further out on its own side.
    static func arcPath(_ a: Airport, _ b: Airport, rank: Int = 0) -> [CLLocationCoordinate2D] {
        arcPath(from: a.coordinate, to: b.coordinate, rank: rank)
    }

    static func arcPath(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, rank: Int = 0) -> [CLLocationCoordinate2D] {
        let p0 = MKMapPoint(from), p2 = MKMapPoint(to)
        let dx = p2.x - p0.x, dy = p2.y - p0.y
        let length = (dx * dx + dy * dy).squareRoot()
        if length == 0 { return [from, to] }
        let bulge = min(0.14 + 0.09 * Double(rank), 0.7)
        // Map points run x east, y south; the right-hand normal of (dx, dy) is (-dy, dx).
        let cx = (p0.x + p2.x) / 2 - dy * bulge
        let cy = (p0.y + p2.y) / 2 + dx * bulge
        let steps = 48
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Double(i) / Double(steps), u = 1 - t
            let x = u * u * p0.x + 2 * u * t * cx + t * t * p2.x
            let y = u * u * p0.y + 2 * u * t * cy + t * t * p2.y
            out.append(MKMapPoint(x: x, y: y).coordinate)
        }
        return out
    }

    /// How far along the bowed arc a real reported position sits — the nearest of
    /// the arc's own sampled points, as a fraction of the way from `a` to `b`. Lets
    /// a live fix (from adsb.lol, say) place the plane precisely while the line
    /// drawn underneath stays the same clean curve, not the raw jagged trail.
    static func fraction(of point: CLLocationCoordinate2D, alongArcFrom a: Airport, to b: Airport) -> Double {
        let coords = arcPath(a, b)
        let target = MKMapPoint(point)
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, c) in coords.enumerated() {
            let d = MKMapPoint(c).distance(to: target)
            if d < bestDistance { bestDistance = d; bestIndex = i }
        }
        return coords.count > 1 ? Double(bestIndex) / Double(coords.count - 1) : 0
    }

    /// Compass bearing from one point to the next, degrees clockwise from north.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let rad = Double.pi / 180
        let dLon = (b.longitude - a.longitude) * rad
        let y = sin(dLon) * cos(b.latitude * rad)
        let x = cos(a.latitude * rad) * sin(b.latitude * rad) - sin(a.latitude * rad) * cos(b.latitude * rad) * cos(dLon)
        return (atan2(y, x) / rad + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The shortest path over the globe; kept for measuring, not drawing.
    static func greatCirclePath(_ a: Airport, _ b: Airport) -> [CLLocationCoordinate2D] {
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
        static let returnColor = UIColor(red: 0.00, green: 0.60, blue: 0.53, alpha: 1)
        static let liveColor = UIColor(red: 0.20, green: 0.70, blue: 0.30, alpha: 1)
        static let selectedColor = UIColor(red: 0.91, green: 0.35, blue: 0.05, alpha: 1)

        /// Northbound (destination the higher latitude) draws blue, southbound green —
        /// due-east/west counts as northbound so nothing is left uncoloured.
        static func directionColor(_ a: Airport, _ b: Airport) -> UIColor {
            b.latitude >= a.latitude ? routeColor : returnColor
        }

        struct Leg { let line: LegPolyline; let from: Airport; let to: Airport; let rank: Int; let baseColor: UIColor }

        var parent: TileMapView
        var legs: [Leg] = []
        /// False until the first real `rebuildOverlays` — distinct from
        /// `map.overlays.isEmpty`, which is also true for a genuinely empty
        /// network and would otherwise wrongly take the recolour-only path
        /// and skip ever adding it.
        var hasBuilt = false
        var framedFor = 0
        var pendingRect: MKMapRect?
        weak var map: MKMapView?
        /// Whether the camera is meant to be following the user right now.
        var following = false
        /// Set while `recenter` itself is moving the camera, so the region
        /// change it causes isn't mistaken for a manual pan that should let go.
        var programmaticChange = false

        init(_ parent: TileMapView) { self.parent = parent }

        /// Frames the legs once the map has a size — with a seventh of it as margin.
        func frameIfPending() {
            guard let map, let rect = pendingRect, map.bounds.width > 0, map.bounds.height > 0 else { return }
            pendingRect = nil
            let pad = min(map.bounds.width, map.bounds.height) / 7
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: pad, left: pad, bottom: pad, right: pad), animated: false)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let leg = overlay as? LegPolyline { return ArrowedPolylineRenderer(overlay: leg) }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "me") as? PulsingUserLocationView
                    ?? PulsingUserLocationView(annotation: annotation, reuseIdentifier: "me")
                view.annotation = annotation
                view.isEnabled = false
                view.canShowCallout = false
                return view
            }
            if let plane = annotation as? PlaneAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "plane") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "plane")
                view.annotation = annotation
                view.image = Self.plane
                // The glyph points up; turn it to the heading.
                view.transform = CGAffineTransform(rotationAngle: plane.heading * .pi / 180)
                view.canShowCallout = false
                return view
            }
            guard let pin = annotation as? AirportAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "airport") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "airport")
            view.annotation = annotation
            view.image = pin.blue ? Self.blueDot : Self.dot
            view.canShowCallout = false
            // The city's name, set just above the dot.
            view.subviews.forEach { $0.removeFromSuperview() }
            if let text = (annotation as? AirportAnnotation)?.label {
                let label = UILabel()
                label.text = text
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .label
                label.layer.shadowColor = UIColor.systemBackground.cgColor
                label.layer.shadowOpacity = 1; label.layer.shadowRadius = 2; label.layer.shadowOffset = .zero
                label.sizeToFit()
                label.center = CGPoint(x: view.bounds.midX, y: -8)
                view.addSubview(label)
            }
            return view
        }

        /// Each new fix while following: a plain re-centre, preserving whatever
        /// zoom is already showing — never MapKit's own tracking-mode camera.
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard following, let loc = userLocation.location else { return }
            recenter(mapView, on: loc.coordinate)
        }

        /// A manual pan or pinch while following: let go, the same way MapKit's
        /// own tracking mode would. This delegate method fires for any region
        /// change though, not just a gesture — MapKit sends one for its own
        /// initial layout settling the moment the map view first appears, with
        /// no user input at all, and `programmaticChange` alone doesn't cover
        /// that (it's not `recenter`'s doing either). Left unguarded, that
        /// phantom callback cancelled following before the first real location
        /// fix ever arrived, so the map never actually centred on it. Only an
        /// actively in-progress drag or pinch on the map's own gesture
        /// recognizers counts as the traveller actually taking hold of it.
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard following, !programmaticChange else { return }
            let userDragging = (mapView.gestureRecognizers ?? []).contains { $0.state == .began || $0.state == .changed }
            guard userDragging else { return }
            following = false
            parent.userTrackingMode?.wrappedValue = .none
        }

        func recenter(_ map: MKMapView, on coordinate: CLLocationCoordinate2D) {
            programmaticChange = true
            let shiftUp = parent.bottomInset / 2
            if shiftUp > 1 {
                // The coordinate sitting `shiftUp` points below `coordinate`'s
                // own current on-screen spot, under the present camera —
                // centring on THAT instead puts `coordinate` itself `shiftUp`
                // points above true centre, clear of whatever's floating over
                // the bottom of the map.
                let point = map.convert(coordinate, toPointTo: map)
                let shifted = map.convert(CGPoint(x: point.x, y: point.y + shiftUp), toCoordinateFrom: map)
                map.setCenter(shifted, animated: true)
            } else {
                map.setCenter(coordinate, animated: true)
            }
            DispatchQueue.main.async { [weak self] in self?.programmaticChange = false }
        }

        /// A tap on an airport dot: the airport itself, not its legs.
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let a = (view.annotation as? AirportAnnotation)?.airport else { return }
            parent.onAirportTap?(a)
            mapView.deselectAnnotation(view.annotation, animated: false)
        }

        /// A tap on the map: the single nearest leg within reach, measured in
        /// points — just that one repeat of the pair, not every flight on it.
        /// An airport's own dot wins first: a line often passes right by one, and
        /// without this a tap meant for the dot would light up its line as well.
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            let p = g.location(in: map)
            for annotation in map.annotations {
                guard let airport = annotation as? AirportAnnotation else { continue }
                let at = map.convert(airport.coordinate, toPointTo: map)
                if hypot(p.x - at.x, p.y - at.y) <= 18 { return }
            }
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
            if let best, best.1 <= 28 { parent.onLegTap?(best.0.from, best.0.to, best.0.rank) }
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

        static let plane: UIImage = {
            let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            let glyph = UIImage(systemName: "airplane", withConfiguration: cfg)!.withTintColor(liveColor, renderingMode: .alwaysOriginal)
            // Rotated once so "up" is north; the annotation view turns it to the heading.
            let size = CGSize(width: 20, height: 20)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                ctx.cgContext.translateBy(x: 10, y: 10)
                ctx.cgContext.rotate(by: -.pi / 2)
                glyph.draw(in: CGRect(x: -glyph.size.width / 2, y: -glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
            }
        }()

        static let dot: UIImage = {
            let size = CGSize(width: 12, height: 12)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor(red: 0.04, green: 0.31, blue: 0.59, alpha: 1).setFill()
                ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: 3, y: 3, width: 6, height: 6))
            }
        }()

        /// A trip's leaving from here within a day, and it's actually reachable —
        /// the same dot, in a colour that pops off the muted basemap.
        static let blueDot: UIImage = {
            let size = CGSize(width: 14, height: 14)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor.systemBlue.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: 3.5, y: 3.5, width: 7, height: 7))
            }
        }()
    }
}

/// An MKMapView that says when it has been laid out, so framing can wait for a real size.
final class SizedMapView: MKMapView {
    var onLaidOut: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 { onLaidOut?() }
    }
}

final class LegPolyline: MKPolyline {
    var color: UIColor = .systemBlue
    var width: CGFloat = 3
    var dashed = false
    var arrow = true
}

/// The aircraft, at the point reached, turned to its heading.
final class PlaneAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let heading: Double
    init(coordinate: CLLocationCoordinate2D, heading: Double) { self.coordinate = coordinate; self.heading = heading }
}

/// The user's own position: a small green dot with a soft ring that bursts
/// outward once every ten seconds — not MapKit's default blue disc, which
/// reads too large next to the thin route lines and pulses continuously.
final class PulsingUserLocationView: MKAnnotationView {
    private let ring = CALayer()
    private var timer: Timer?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        let green = UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)

        ring.frame = bounds
        ring.cornerRadius = bounds.width / 2
        ring.backgroundColor = UIColor.clear.cgColor
        ring.borderColor = green.cgColor
        ring.borderWidth = 1.5
        ring.opacity = 0
        layer.addSublayer(ring)

        let dotSize: CGFloat = 10
        let core = CALayer()
        core.frame = CGRect(x: (bounds.width - dotSize) / 2, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
        core.cornerRadius = dotSize / 2
        core.backgroundColor = green.cgColor
        core.borderColor = UIColor.white.cgColor
        core.borderWidth = 1.5
        layer.addSublayer(core)

        schedulePulse()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func schedulePulse() {
        pulseOnce()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.pulseOnce() }
    }

    private func pulseOnce() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0; scale.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.1
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        timer?.invalidate()
        schedulePulse()
    }
    // No deinit invalidating the timer: this view lives as long as the map
    // does, and a repeating Timer holding only a weak self is harmless to
    // leave running past that — Swift 6's actor isolation won't let a
    // nonisolated deinit touch a main-actor Timer property anyway.
}

final class AirportAnnotation: NSObject, MKAnnotation {
    let airport: Airport
    let label: String?
    /// A trip leaving from here within a day, and a route to it actually exists.
    let blue: Bool
    var coordinate: CLLocationCoordinate2D { airport.coordinate }
    init(airport: Airport, label: String? = nil, blue: Bool = false) { self.airport = airport; self.label = label; self.blue = blue }
}

extension Airport {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// The line plus one arrowhead at its midpoint, pointing the way the flight goes.
final class ArrowedPolylineRenderer: MKPolylineRenderer {
    // init(overlay:) is the designated initializer MapKit actually calls.
    override init(overlay: MKOverlay) {
        super.init(overlay: overlay)
        let leg = overlay as? LegPolyline
        strokeColor = leg?.color ?? .systemBlue
        lineWidth = leg?.width ?? 3
        lineJoin = .round
        lineCap = .round
        if leg?.dashed == true { lineDashPattern = [4, 4] }
    }

    /// Thinner the further out the map is: full weight around city level, a third
    /// of it when a continent is on screen, so a network does not clot.
    private func weight(at zoomScale: MKZoomScale) -> CGFloat {
        let level = log2(Double(zoomScale)) + 20  // ~20 at street level, ~3 for a continent
        return CGFloat(min(1.0, max(0.25, 0.25 + (level - 3) * 0.09)))
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let w = weight(at: zoomScale)
        lineWidth = ((polyline as? LegPolyline)?.width ?? 3) * w
        super.draw(mapRect, zoomScale: zoomScale, in: context)
        guard let leg = polyline as? LegPolyline, leg.arrow, leg.pointCount >= 2 else { return }
        let pts = leg.points()
        let mid = leg.pointCount / 2
        let a = point(for: pts[max(0, mid - 1)]), b = point(for: pts[min(leg.pointCount - 1, mid + 1)])
        let m = point(for: pts[mid])
        let angle: CGFloat = atan2(b.y - a.y, b.x - a.x)
        let size: CGFloat = 7 * w / zoomScale
        context.saveGState()
        context.translateBy(x: m.x, y: m.y)
        context.rotate(by: angle)
        context.move(to: CGPoint(x: size, y: 0))
        context.addLine(to: CGPoint(x: -size * 0.9, y: -size * 0.8))
        context.addLine(to: CGPoint(x: -size * 0.4, y: 0))
        context.addLine(to: CGPoint(x: -size * 0.9, y: size * 0.8))
        context.closePath()
        context.setFillColor(leg.color.cgColor)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.2 * w / zoomScale)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }
}
