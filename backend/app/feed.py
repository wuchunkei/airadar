"""
Automatic plausibility scoring for a manually-entered ("fed") trip — see
TripIn.feedStatus in trips.py. A traveller who searched for a flight and
came up empty types it in by hand instead; every one of those becomes a
data point, scored here before it's ever stored, purely from sources this
backend already talks to or already holds:

  +50  AirLabs' schedule, or AeroDataBox's own candidates, has a flight
       under this exact number, on this exact day, between these two
       airports
  +25  adsbdb (github.com/mrjackwills/adsbdb, free and keyless) recognises
       the flight number's callsign and its own published route agrees —
       a second, independent source from AirLabs/AeroDataBox entirely
  +10  both airports are real, known IATA codes
  +30  at least one OTHER traveller has independently fed the identical
       flight number, day and route already — the strongest single
       signal, since two strangers fabricating the same story by
       coincidence is unlikely

>=70 auto-approves; <20 auto-rejects (the trip is then shown blocked on
the traveller's own Trip card — a red outline, still editable or
deletable, never silently discarded); anything between is left pending,
neither verified nor blocked, until a later corroborating traveller or a
real source closes the gap.

None of this proves a *specific* person flew — only a real trip fed
elsewhere would let it corroborate at all — it establishes that the
flight itself was real, which is the one thing worth checking
automatically. (A separate, client-side check catches the "whose flight
is this really" question instead: FlightConflicts.overlapping in
Airadar/Models/Models.swift flags two of one traveller's own flights
overlapping in time, which nothing here needs to know about.)

Not implemented yet, both deliberately out of scope for a first pass:
requiring a photo of the boarding pass/ticket for anything under the
reject line instead of just rejecting outright, and re-scoring a trip
already sitting at "pending" when a later traveller's submission would
have corroborated it.
"""

from datetime import date

import airportsdata
import httpx

from . import aerodatabox, airlabs

APPROVE_AT = 70
REJECT_BELOW = 20

_AIRPORTS = airportsdata.load("IATA")


async def _schedule_confirms(client: httpx.AsyncClient, number: str, day: date, dep: str, arr: str) -> bool:
    try:
        f = await airlabs.lookup(client, number, day)
        if f.departure == dep and f.arrival == arr:
            return True
    except Exception:
        pass
    try:
        candidates = await aerodatabox.flights(client, number, day)
        return any(c.departure == dep and c.arrival == arr for c in candidates)
    except Exception:
        return False


async def _adsbdb_confirms(client: httpx.AsyncClient, number: str, dep: str, arr: str) -> bool:
    """adsbdb keeps a static airline-route assignment per flight number,
    independent of AirLabs/AeroDataBox's own timetables — a real second
    source, not just a fallback for when the first one is empty."""
    try:
        resp = await client.get(f"https://api.adsbdb.com/v0/callsign/{number.upper()}", timeout=8)
        route = (resp.json().get("response") or {}).get("flightroute") or {}
        origin = (route.get("origin") or {}).get("iata_code")
        destination = (route.get("destination") or {}).get("iata_code")
        return bool(origin) and bool(destination) and origin == dep and destination == arr
    except Exception:
        return False


def _airports_known(dep: str, arr: str) -> bool:
    return dep.upper() in _AIRPORTS and arr.upper() in _AIRPORTS


async def _corroborated(db, user_id, number: str, day_str: str, dep: str, arr: str) -> bool:
    """Another traveller, not this one, has already fed the identical flight."""
    cursor = db.trips.find({
        "userId": {"$ne": user_id},
        "isManual": True,
        "flightNumber": number,
        "departure": dep,
        "arrival": arr,
        "deletedAt": None,
    })
    async for doc in cursor:
        dep_time = doc.get("departureTime")
        if dep_time and str(dep_time)[:10] == day_str:
            return True
    return False


async def score(http: httpx.AsyncClient, db, user_id, number: str, day: date, dep: str, arr: str) -> str:
    """The resolved feedStatus for a fresh manual entry — "approved",
    "rejected", or "pending". Never trust the client's own say-so for
    this: it always arrives as "pending" and this is what actually
    decides it, before the trip is ever stored."""
    total = 0
    if await _schedule_confirms(http, number, day, dep, arr):
        total += 50
    if await _adsbdb_confirms(http, number, dep, arr):
        total += 25
    if _airports_known(dep, arr):
        total += 10
    if await _corroborated(db, user_id, number, day.isoformat(), dep, arr):
        total += 30
    if total >= APPROVE_AT:
        return "approved"
    if total < REJECT_BELOW:
        return "rejected"
    return "pending"
