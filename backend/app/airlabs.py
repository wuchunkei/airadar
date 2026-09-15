"""AirLabs — primary status source. Port of the Android AirLabsClient."""

import os
from datetime import date, datetime, timedelta

import re

import httpx
import pycountry
from timezonefinder import TimezoneFinder

from .schema import Airport, Flight, FlightStatus, flight_id

_tzf = TimezoneFinder(in_memory=True)

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
    return _parse(await _with_airline_name(client, row, number), number, day)


async def lookup(client: httpx.AsyncClient, number: str, day: date) -> Flight:
    """Live status if AirLabs has this very day's flight; the timetable otherwise.
    A live record for a different day is never passed off as the asked-for one."""
    if abs((day - date.today()).days) <= 1:
        try:
            live = await flight(client, number, day)
            if live.departureTime.date() == day:
                return live
        except AirLabsError as e:
            if e.quota_exhausted:
                raise
    return await schedule(client, number, day)


async def schedule(client: httpx.AsyncClient, number: str, day: date) -> Flight:
    """Timetable row for a future date (no live status)."""
    body = await _get(client, "schedules", flight_iata=number.upper())
    rows = body.get("response") or []
    if not rows:
        hint = await _adsbdb_route_hint(client, number)
        raise AirLabsError(
            f"AirLabs has no schedule for {number.upper()} anymore — likely renumbered, "
            f"seasonal, or discontinued since." + hint
        )
    row = next((r for r in rows if str(r.get("dep_time", "")).startswith(day.isoformat())), None)
    if row is not None:
        return _parse(await _with_airline_name(client, row, number), number, day)
    # AirLabs only lists the next day or two. Further out, the timetable is the
    # same clock times on the asked-for day, with nothing live attached to it.
    return _rebase(_parse(await _with_airline_name(client, rows[0], number), number, day), day)


async def _adsbdb_route_hint(client: httpx.AsyncClient, number: str) -> str:
    """A free, keyless fallback for the *route alone*, when AirLabs no longer
    operates a flight number at all — renumbered, seasonal, long discontinued.
    adsbdb (github.com/mrjackwills/adsbdb) has no schedule/time data either, so
    this only ever enriches the error message, never stands in for a real
    Flight: a traveller reading it at least knows which airports to add by
    hand rather than being told nothing more than "not found". Never raises —
    a network hiccup here should not change how the caller's own error reads.
    """
    try:
        resp = await client.get(f"https://api.adsbdb.com/v0/callsign/{number.upper()}", timeout=8)
        route = (resp.json().get("response") or {}).get("flightroute") or {}
        origin = (route.get("origin") or {}).get("iata_code")
        destination = (route.get("destination") or {}).get("iata_code")
        if origin and destination:
            return f" adsbdb still has its route though: {origin} → {destination} — worth adding by hand with the real times from your own booking."
    except Exception:
        pass
    return ""


def _rebase(f: Flight, day: date) -> Flight:
    span = (f.arrivalTime.date() - f.departureTime.date()).days
    return f.model_copy(update={
        "departureTime": datetime.combine(day, f.departureTime.time()),
        "arrivalTime": datetime.combine(day + timedelta(days=span), f.arrivalTime.time()),
        "status": FlightStatus.SCHEDULED,
        "delayMinutes": 0,
        "departureGate": None,
        "arrivalGate": None,
        "baggageClaim": None,
    })


_airline_names: dict[str, str] = {}


async def airline_name(client: httpx.AsyncClient, iata: str) -> str | None:
    """Timetable rows carry only the airline code; the name comes from /airlines, once."""
    iata = iata.upper()
    if iata not in _airline_names:
        try:
            body = await _get(client, "airlines", iata_code=iata)
            rows = body.get("response") or []
            _airline_names[iata] = (rows[0].get("name") if rows else None) or ""
        except AirLabsError:
            return None
    return _airline_names[iata] or None


async def _with_airline_name(client: httpx.AsyncClient, row: dict, number: str) -> dict:
    if not row.get("airline_name"):
        code = row.get("airline_iata") or number[:2]
        name = await airline_name(client, code)
        if name:
            row = {**row, "airline_name": name}
    return row


async def airport(client: httpx.AsyncClient, iata: str) -> Airport:
    body = await _get(client, "airports", iata_code=iata.upper())
    rows = body.get("response") or []
    if not rows:
        raise AirLabsError(f"AirLabs has no airport with code {iata.upper()}.")
    r = rows[0]
    lat, lng = float(r["lat"]), float(r["lng"])
    name = r.get("name") or iata.upper()
    code = (r.get("country_code") or "").upper()
    country = pycountry.countries.get(alpha_2=code)
    return Airport(
        iata=r["iata_code"],
        icao=r.get("icao_code") or "",
        name=name,
        city=await _city_name(client, r.get("city_code"), name),
        country=(getattr(country, "common_name", None) or getattr(country, "name", None) or code) if country else code,
        countryCode=code,
        latitude=lat,
        longitude=lng,
        # AirLabs rarely names the zone; the coordinates always know it.
        zoneId=r.get("timezone") or _tzf.timezone_at(lat=lat, lng=lng) or "UTC",
    )


_AIRPORT_WORDS = re.compile(r"\s+(international|intl\.?|regional|municipal|airport|airfield|field).*$", re.I)


async def _city_name(client: httpx.AsyncClient, city_code: str | None, airport_name: str) -> str:
    """The city from AirLabs' cities table; failing that, the airport name shorn of "… International Airport"."""
    if city_code:
        try:
            rows = (await _get(client, "cities", city_code=city_code)).get("response") or []
            if rows and rows[0].get("name"):
                return rows[0]["name"]
        except AirLabsError:
            pass
    return _AIRPORT_WORDS.sub("", airport_name).strip() or airport_name


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


def _terminal(row: dict, key: str) -> str | None:
    """Airlines write "1", "T1" or "Terminal 1"; the apps add their own "T"."""
    v = _text(row, key)
    if v is None:
        return None
    return re.sub(r"^\s*(terminal|t)\s*", "", v, flags=re.I).strip() or None


def _status(status: str, delayed: int) -> FlightStatus:
    return {
        "cancelled": FlightStatus.CANCELLED,
        "diverted": FlightStatus.DIVERTED,
        "landed": FlightStatus.LANDED,
        "active": FlightStatus.IN_FLIGHT,
        "en-route": FlightStatus.IN_FLIGHT,
        "boarding": FlightStatus.BOARDING,
        "departed": FlightStatus.DEPARTED,
    }.get((status or "").lower(), FlightStatus.DELAYED if delayed > 0 else FlightStatus.SCHEDULED)


def _delay_minutes(row: dict, std: datetime) -> int:
    """AirLabs spreads the delay over several fields, and drops some once the flight is
    off: the plain `delayed`, the departure one, or the gap between the scheduled and
    the estimated/actual departure — whichever it still tells."""
    for key in ("dep_delayed", "delayed"):
        try:
            v = int(row.get(key) or 0)
        except (TypeError, ValueError):
            v = 0
        if v > 0:
            return v
    for key in ("dep_actual", "dep_estimated"):
        if (moved := _time(row, key)) is not None:
            return max(0, int((moved - std).total_seconds() // 60))
    return 0


def _parse(row: dict, number: str, day: date) -> Flight:
    number = number.upper()
    dep, arr = (row.get("dep_iata") or "").upper(), (row.get("arr_iata") or "").upper()
    if not dep or not arr:
        raise AirLabsError(f"AirLabs record for {number} has no route.")
    std, sta = _time(row, "dep_time"), _time(row, "arr_time")
    if not std or not sta:
        raise AirLabsError(f"AirLabs record for {number} has no scheduled times.")
    delayed = _delay_minutes(row, std)
    return Flight(
        id=flight_id(number, day),
        flightNumber=number,
        airlineName=row.get("airline_name") or number[:2],
        departure=dep,
        arrival=arr,
        departureTerminal=_terminal(row, "dep_terminal"),
        arrivalTerminal=_terminal(row, "arr_terminal"),
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
