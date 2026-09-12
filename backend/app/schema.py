"""Wire shape handed to the Android app. Mirrors data/Models.kt one field for one."""

from datetime import date, datetime
from enum import Enum

from pydantic import BaseModel


class FlightStatus(str, Enum):
    ON_TIME = "ON_TIME"
    DELAYED = "DELAYED"
    CANCELLED = "CANCELLED"
    DIVERTED = "DIVERTED"
    SCHEDULED = "SCHEDULED"
    COMPLETED = "COMPLETED"
    BOARDING = "BOARDING"
    DEPARTED = "DEPARTED"
    IN_FLIGHT = "IN_FLIGHT"
    LANDED = "LANDED"


class Flight(BaseModel):
    id: str
    flightNumber: str
    airlineName: str
    departure: str
    arrival: str
    departureTerminal: str | None = None
    arrivalTerminal: str | None = None
    departureGate: str | None = None
    arrivalGate: str | None = None
    departureTime: datetime
    arrivalTime: datetime
    status: FlightStatus
    aircraft: str | None = None
    baggageClaim: str | None = None
    delayMinutes: int = 0
    callsign: str | None = None

    source: str


class Airport(BaseModel):
    iata: str
    icao: str
    name: str
    city: str
    country: str
    countryCode: str
    latitude: float
    longitude: float
    zoneId: str


def flight_id(number: str, day: date) -> str:
    return f"{number.upper()}-{day.isoformat()}"
