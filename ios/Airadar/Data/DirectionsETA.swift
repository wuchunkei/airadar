import MapKit

/// Apple's own free routing between two points — just the time, not the route,
/// and no key needed. Shared by anything that asks "how long from here to
/// there": the airport info sheet's two buttons, and the map's blue-dot check.
enum DirectionsETA {
    static func seconds(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                        by transportType: MKDirectionsTransportType) async -> TimeInterval? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = transportType
        return try? await MKDirections(request: request).calculateETA().expectedTravelTime
    }
}
