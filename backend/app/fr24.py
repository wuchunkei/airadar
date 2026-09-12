"""
Past flights, through the history service (fr24/ in this repo) that runs on a
separate machine. Answers are cached in Mongo so a flight is asked about once.
"""

import os
from datetime import date, datetime, timezone

import httpx

from .schema import Flight, FlightStatus, flight_id

CACHE_DAYS = 90


class HistoryError(Exception):
    pass


def enabled() -> bool:
    return bool(os.environ.get("FR24_SERVICE_URL", "").strip())


async def flight(client: httpx.AsyncClient, db, number: str, day: date) -> Flight:
    number = number.upper()
    key = f"{number}:{day.isoformat()}"
    cached = await db.flightCache.find_one({"_id": key})
    if cached:
        if cached.get("miss"):
            raise HistoryError(f"No record of {number} on {day} (checked recently).")
        return Flight(**cached["flight"])

    base = os.environ.get("FR24_SERVICE_URL", "").strip().rstrip("/")
    token = os.environ.get("FR24_SERVICE_TOKEN", "").strip()
    try:
        r = await client.get(f"{base}/history/{number}/{day.isoformat()}",
                             headers={"X-Service-Token": token}, timeout=60)
    except httpx.HTTPError as e:
        raise HistoryError(f"History service unreachable: {e}")

    now = datetime.now(timezone.utc)
    if r.status_code == 404:
        await db.flightCache.replace_one({"_id": key}, {"_id": key, "miss": True, "cachedAt": now}, upsert=True)
        raise HistoryError(f"No record of {number} on {day}.")
    if r.status_code != 200:
        raise HistoryError(f"History service answered HTTP {r.status_code}.")

    row = r.json()
    f = Flight(
        id=flight_id(number, day),
        flightNumber=number,
        airlineName=row.get("airlineName") or number[:2],
        departure=row["departure"],
        arrival=row["arrival"],
        departureTerminal=row.get("departureTerminal"),
        arrivalTerminal=row.get("arrivalTerminal"),
        departureGate=row.get("departureGate"),
        arrivalGate=row.get("arrivalGate"),
        departureTime=datetime.fromisoformat(row["departureTime"]),
        arrivalTime=datetime.fromisoformat(row["arrivalTime"] or row["departureTime"]),
        status=FlightStatus(row.get("status") or "SCHEDULED"),
        aircraft=row.get("aircraft"),
        baggageClaim=row.get("baggageClaim"),
        delayMinutes=int(row.get("delayMinutes") or 0),
        callsign=row.get("callsign"),
        source="fr24",
    )
    await db.flightCache.replace_one(
        {"_id": key}, {"_id": key, "flight": f.model_dump(mode="json"), "cachedAt": now}, upsert=True
    )
    return f
