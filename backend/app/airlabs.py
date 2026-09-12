"""AirLabs — primary status source. Port of the Android AirLabsClient."""

import os
from datetime import date, datetime

import httpx

from .schema import Airport, Flight, FlightStatus, flight_id

BASE = "https://airlabs.co/api/v9"


class AirLabsError(Exception):
    def __init__(self, message: str, quota_exhausted: bool = False):
        super().__init__(message)
        self.quota_exhausted = quota_exhausted


def _key() -> str:
    key = os.environ.get("AIRLABS_API_KEY", "").strip()
    if not key:
        raise AirLabsError("AIRLABS_API_KEY is not set on the server.")
    return key


async def _get(client: httpx.AsyncClient, path: str, **params) -> dict:
    params["api_key"] = _key()
    resp = await client.get(f"{BASE}/{path}", params=params, timeout=30)
    body = resp.json()
    if err := body.get("error"):
        code = err.get("code", "")
        if code == "limit_reached":
            raise AirLabsError("AirLabs monthly quota used up.", quota_exhausted=True)
        if code in ("unknown_api_key", "wrong_api_key"):
            raise AirLabsError("AirLabs rejected the API key.")
        raise AirLabsError(f"AirLabs: {err.get('message', code)}")
    return body


async def flight(client: httpx.AsyncClient, number: str, day: date) -> Flight:
    """Live status; AirLabs only carries this around the current day."""
    body = await _get(client, "flight", flight_iata=number.upper())
    row = body.get("response")
    if not row:
        raise AirLabsError(
            f"AirLabs has no live record of {number.upper()}; it only tracks flights "
            "around the current day."
        )
    return _parse(row, number, day)


async def schedule(client: httpx.AsyncClient, number: str, day: date) -> Flight:
    """Timetable row for a future date (no live status)."""
    body = await _get(client, "schedules", flight_iata=number.upper())
    rows = body.get("response") or []
    if not rows:
        raise AirLabsError(f"AirLabs has no schedule for {number.upper()}.")
    row = next((r for r in rows if str(r.get("dep_time", "")).startswith(day.isoformat())), rows[0])
    return _parse(row, number, day)


async def airport(client: httpx.AsyncClient, iata: str) -> Airport:
    body = await _get(client, "airports", iata_code=iata.upper())
    rows = body.get("response") or []
    if not rows:
        raise AirLabsError(f"AirLabs has no airport with code {iata.upper()}.")
    r = rows[0]
    return Airport(
        iata=r["iata_code"],
        icao=r.get("icao_code") or "",
        name=r.get("name") or iata.upper(),
        city=r.get("city") or r.get("name") or iata.upper(),
        country=r.get("country_code") or "",
        countryCode=r.get("country_code") or "",
        latitude=float(r["lat"]),
        longitude=float(r["lng"]),
        zoneId=r.get("timezone") or "UTC",
    )


def _time(row: dict, key: str) -> datetime | None:
    raw = row.get(key)
    if not raw or raw == "null":
        return None
    try:
        return datetime.strptime(str(raw)[:16], "%Y-%m-%d %H:%M")
    except ValueError:
        return None


def _text(row: dict, key: str) -> str | None:
    v = row.get(key)
    return None if v in (None, "", "null") else str(v)


def _status(status: str, delayed: int) -> FlightStatus:
    return {
        "cancelled": FlightStatus.CANCELLED,
        "diverted": FlightStatus.DIVERTED,
        "landed": FlightStatus.LANDED,
        "active": FlightStatus.IN_FLIGHT,
    }.get(status, FlightStatus.DELAYED if delayed > 0 else FlightStatus.SCHEDULED)


def _parse(row: dict, number: str, day: date) -> Flight:
    number = number.upper()
    dep, arr = (row.get("dep_iata") or "").upper(), (row.get("arr_iata") or "").upper()
    if not dep or not arr:
        raise AirLabsError(f"AirLabs record for {number} has no route.")
    std, sta = _time(row, "dep_time"), _time(row, "arr_time")
    if not std or not sta:
        raise AirLabsError(f"AirLabs record for {number} has no scheduled times.")
    delayed = max(int(row.get("delayed") or 0), 0)
    return Flight(
        id=flight_id(number, day),
        flightNumber=number,
        airlineName=row.get("airline_name") or number[:2],
        departure=dep,
        arrival=arr,
        departureTerminal=_text(row, "dep_terminal"),
        arrivalTerminal=_text(row, "arr_terminal"),
        departureGate=_text(row, "dep_gate"),
        arrivalGate=_text(row, "arr_gate"),
        departureTime=std,
        arrivalTime=sta,
        status=_status(row.get("status", ""), delayed),
        aircraft=_text(row, "aircraft_icao"),
        baggageClaim=_text(row, "arr_baggage"),
        delayMinutes=delayed,
        callsign=_text(row, "flight_icao"),
        source="airlabs",
    )
