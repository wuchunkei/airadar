import CoreLocation

/// Names whatever the aircraft is over right now, from its live fix alone --
/// Apple's own free reverse geocoder, same one MapKit itself uses, so no new
/// key or quota to manage. A courtesy note on the detail sheet while a flight
/// is in the air, not a fact stored anywhere.
enum PassingLocation {
    static func describe(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // A fresh geocoder per call rather than one shared instance -- cheap
        // to create, and sidesteps CLGeocoder not being Sendable.
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        // A city or town first; failing that, whatever region/state the point
        // falls in (open countryside still resolves to one); over water,
        // CLPlacemark still names the ocean or sea, which reads better than
        // nothing for the long stretches of a flight that are neither.
        if let city = placemark.locality ?? placemark.administrativeArea {
            return [city, placemark.country].compactMap { $0 }.joined(separator: ", ")
        }
        if let ocean = placemark.ocean { return ocean }
        if let inlandWater = placemark.inlandWater { return inlandWater }
        return placemark.country
    }
}
