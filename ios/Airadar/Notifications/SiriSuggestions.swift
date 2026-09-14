import Foundation
import Intents

/// Siri Event Suggestions: each upcoming trip is donated as a flight reservation,
/// so the system can offer it in Calendar, Maps and on the lock screen the way it
/// does for flights found in Mail — the app-side counterpart of Apple's markup.
enum SiriSuggestions {

    static func donate(_ flight: Flight) {
        guard flight.phase != .past, !flight.isPending,
              let dep = flight.departureAirport, let arr = flight.arrivalAirport else { return }

        let airlineCode = String(flight.flightNumber.prefix(2))
        let airline = INAirline(name: flight.airlineName.isEmpty ? airlineCode : flight.airlineName,
                                iataCode: airlineCode, icaoCode: AirportDatabase.shared.airlineIcao(airlineCode))
        let depAirport = INAirport(name: dep.name, iataCode: dep.iata, icaoCode: dep.icao)
        let arrAirport = INAirport(name: arr.name, iataCode: arr.iata, icaoCode: arr.icao)
        let depGate = INAirportGate(airport: depAirport, terminal: flight.departureTerminal, gate: flight.departureGate)
        let arrGate = INAirportGate(airport: arrAirport, terminal: flight.arrivalTerminal, gate: flight.arrivalGate)

        var start = flight.departureTime.localDate
        start.hour = flight.departureTime.hour; start.minute = flight.departureTime.minute; start.timeZone = dep.zone
        var end = flight.arrivalTime.localDate
        end.hour = flight.arrivalTime.hour; end.minute = flight.arrivalTime.minute; end.timeZone = arr.zone

        let inFlight = INFlight(airline: airline,
                                flightNumber: String(flight.flightNumber.dropFirst(2)),
                                boardingTime: nil,
                                flightDuration: INDateComponentsRange(start: start, end: end),
                                departureAirportGate: depGate,
                                arrivalAirportGate: arrGate)

        let reference = INSpeakableString(vocabularyIdentifier: flight.id, spokenPhrase: flight.flightNumber, pronunciationHint: nil)
        let reservation = INFlightReservation(itemReference: reference,
                                              reservationNumber: flight.pnr ?? flight.id,
                                              bookingTime: nil,
                                              reservationStatus: .confirmed,
                                              reservationHolderName: nil,
                                              actions: nil,
                                              url: nil,
                                              reservedSeat: nil,
                                              flight: inFlight)

        let intent = INGetReservationDetailsIntent(reservationContainerReference: reference, reservationItemReferences: [reference])
        let response = INGetReservationDetailsIntentResponse(code: .success, userActivity: nil)
        response.reservations = [reservation]
        let interaction = INInteraction(intent: intent, response: response)
        interaction.identifier = flight.id
        interaction.donate { _ in }
    }

    static func forget(_ flightId: String) {
        INInteraction.delete(with: [flightId]) { _ in }
    }
}
