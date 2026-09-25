import CoreLocation
import MapKit
import UIKit

/// Turns a departure airport into turn-by-turn directions, in whichever of the
/// traveller's map apps they'd rather use -- not just Apple's own.
enum MapProvider: String, CaseIterable, Identifiable {
    case apple, google, amap
    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: String(localized: "Apple Maps")
        case .google: String(localized: "Google Maps")
        case .amap: String(localized: "Amap")
        }
    }

    /// Whether the app itself is on the phone -- Apple Maps always is.
    var isInstalled: Bool {
        switch self {
        case .apple: true
        case .google: UIApplication.shared.canOpenURL(URL(string: "comgooglemaps://")!)
        case .amap: UIApplication.shared.canOpenURL(URL(string: "iosamap://")!)
        }
    }

    /// Every provider whose app is installed, Apple Maps always first.
    static var available: [MapProvider] { allCases.filter(\.isInstalled) }

    @MainActor
    func open(to airport: Airport) {
        let lat = airport.coordinate.latitude, lon = airport.coordinate.longitude
        let name = airport.iata
        switch self {
        case .apple:
            let item = MKMapItem(placemark: MKPlacemark(coordinate: airport.coordinate))
            item.name = name
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        case .google:
            let scheme = "comgooglemaps://?daddr=\(lat),\(lon)&directionsmode=driving"
            let web = "https://www.google.com/maps/dir/?api=1&destination=\(lat),\(lon)&travelmode=driving"
            open(scheme, orElse: web)
        case .amap:
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            let scheme = "iosamap://path?sourceApplication=Airadar&dlat=\(lat)&dlon=\(lon)&dname=\(encodedName)&dev=0&t=0"
            let web = "https://uri.amap.com/navigation?to=\(lon),\(lat),\(encodedName)&mode=car&src=Airadar&coordinate=gaode"
            open(scheme, orElse: web)
        }
    }

    @MainActor
    private func open(_ scheme: String, orElse web: String) {
        if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: web) {
            UIApplication.shared.open(url)
        }
    }
}

/// Whether a real, drivable road route to an airport exists from wherever the
/// traveller is right now -- so "in 24h" doesn't turn blue for someone whose
/// nearest airport is a flight of its own away, or before a location fix
/// exists to check against at all. Built on the same coarse fix and free
/// Apple routing `AirportInfoSheet`'s own ETA buttons already use, so this
/// asks nothing new of location permissions.
@MainActor
enum RouteValidity {
    static func hasDrivableRoute(to airport: Airport) async -> Bool {
        guard let here = await HomeRegion.coarseCoordinate() else { return false }
        return await DirectionsETA.seconds(from: here, to: airport.coordinate, by: .automobile) != nil
    }
}
