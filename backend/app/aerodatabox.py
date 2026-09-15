"""AeroDataBox — fallback schedule source for a flight AirLabs' own coverage
has nothing under at all (a real, common gap: AirLabs' schedules endpoint
simply doesn't carry every airline). Same RapidAPI service the iOS app itself
calls for post-hoc enrichment; here it can produce a real Flight outright,
real scheduled times included, not just enrich an error message.

Needs its own AERODATABOX_KEY — a RapidAPI key, free tier 400 "API units" a
month, 2 spent per lookup here. If it's the same key the iOS app already
carries, the two share that budget; a second free RapidAPI key keeps them
apart.
"""

import os
from datetime import date, datetime

import httpx

from .schema import Flight, FlightStatus, flight_id

API = "https://aerodatabox.p.rapidapi.com"


class AeroDataBoxError(Exception):
    pass


def _key() -> str:
    key = os.environ.get("AERODATABOX_KEY", "").strip()
    if not key:
        raise AeroDataBoxError("AERODATABOX_KEY is not set on the server.")
    return key


_STATUS = {
    "scheduled": FlightStatus.SCHEDULED,
    "departed": FlightStatus.DEPARTED,
    "enroute": FlightStatus.IN_FLIGHT,
    "arrived": FlightStatus.LANDED,
    "canceled": FlightStatus.CANCELLED,
    "cancelled": FlightStatus.CANCELLED,
    "diverted": FlightStatus.DIVERTED,
}


def _status(raw: str | None) -> FlightStatus:
    return _STATUS.get((raw or "").lower(), FlightStatus.SCHEDULED)


def _local(node: dict | None, key: str) -> datetime | None:
    """The wall clock at that airport — "2026-09-14 23:10+08:00" under
    node[key]["local"] — not node[key]["utc"]: Flight.departureTime/
    arrivalTime carry no zone of their own, the airport's own zone is what
    the app reads them against, so a UTC value here would show hours off."""
    raw = ((node or {}).get(key) or {}).get("local")
    if not raw:
        return None
    # Strip a trailing "+08:00" / "-05:00" offset (always 6 characters) if present.
    base = raw[:-6] if len(raw) > 6 and raw[-6] in "+-" else raw
    try:
        return datetime.strptime(base, "%Y-%m-%d %H:%M")
    except ValueError:
        return None


async def flight(client: httpx.AsyncClient, number: str, day: date) -> Flight:
    cleaned = number.upper().replace(" ", "")
    url = f"{API}/flights/number/{cleaned}/{day.isoformat()}"
    headers = {"x-rapidapi-key": _key(), "x-rapidapi-host": "aerodatabox.p.rapidapi.com"}
    resp = await client.get(url, headers=headers, timeout=20)
    if resp.status_code == 404:
        raise AeroDataBoxError(f"AeroDataBox has nothing for {cleaned} on {day.isoformat()}.")
    if resp.status_code != 200:
        raise AeroDataBoxError(f"AeroDataBox answered HTTP {resp.status_code} for {cleaned}.")
    rows = resp.json() or []
    if not rows:
        raise AeroDataBoxError(f"AeroDataBox found no flights for {cleaned} on {day.isoformat()}.")

    # "Both" (the default role) can hand back a departure-day row and an
    # arrival-day row for an overnight flight; the one whose own departure
    # falls on the asked-for local day is the one that actually matches it.
    def local_day(row: dict) -> str:
        return ((row.get("departure") or {}).get("scheduledTime") or {}).get("local", "")

    row = next((r for r in rows if local_day(r).startswith(day.isoformat())), rows[0])
    dep, arr = row.get("departure") or {}, row.get("arrival") or {}
    dep_iata = ((dep.get("airport") or {}).get("iata") or "").upper()
    arr_iata = ((arr.get("airport") or {}).get("iata") or "").upper()
    std, sta = _local(dep, "scheduledTime"), _local(arr, "scheduledTime")
    if not (dep_iata and arr_iata and std and sta):
        raise AeroDataBoxError(f"AeroDataBox's record for {cleaned} is missing a route or a schedule.")

    current_dep = _local(dep, "revisedTime") or _local(dep, "runwayTime") or std
    delay = max(0, round((current_dep - std).total_seconds() / 60))
    callsign = (row.get("callSign") or "").replace(" ", "") or None

    return Flight(
        id=flight_id(cleaned, day),
        flightNumber=cleaned,
        airlineName=(row.get("airline") or {}).get("name") or cleaned[:2],
        departure=dep_iata,
        arrival=arr_iata,
        departureTerminal=dep.get("terminal"),
        arrivalTerminal=arr.get("terminal"),
        departureGate=dep.get("gate"),
        arrivalGate=arr.get("gate"),
        departureTime=std,
        arrivalTime=sta,
        status=_status(row.get("status")),
        aircraft=(row.get("aircraft") or {}).get("model"),
        delayMinutes=delay,
        callsign=callsign,
        source="aerodatabox",
    )
