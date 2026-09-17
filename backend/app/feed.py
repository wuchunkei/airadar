"""
Automatic plausibility scoring for a manually-entered ("fed") trip — see
TripIn.feedStatus in trips.py. A traveller who searched for a flight and
came up empty types it in by hand instead; every one of those becomes a
data point, scored here before it's ever stored, purely from sources this
backend already talks to or already holds:

  +50  AirLabs' schedule, AeroDataBox's own candidates, or this app's own
       feed_schedules collection (below) has a flight under this exact
       number, on this exact day, between these two airports
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

feed_schedules — the local feed database
------------------------------------------
Every flight this scoring approves teaches its number+route to
`db.feed_schedules`, keyed on exactly that pair (not the date — a
recurring flight's calendar day changes every time, its schedule mostly
doesn't). The very first approval sets the canonical time of day; later
approvals only confirm it (bumping sampleCount) rather than overwriting
it, so one later traveller's own possibly-off entry can't quietly corrupt
a schedule several people already confirmed.

Two things then read it back:
  - `score()` itself, as a fourth schedule source alongside AirLabs/
    AeroDataBox — once the community has confirmed a number+route once,
    the next traveller feeding the same one clears the schedule signal
    even though AirLabs and AeroDataBox still have nothing.
  - `schedule_for_search()`, called from main.py's own /flights endpoints
    once AirLabs and AeroDataBox both fail — so a later traveller
    searching for the exact same flight gets it served straight back
    instead of hitting the same dead end and having to type it in all
    over again themselves.

A short delay or an early departure is normal, not a sign of a different
flight — matching a submission's own stated time against a feed_schedules
entry allows TIME_TOLERANCE_MINUTES of slack either way, in both
directions across midnight.

Not implemented yet, both deliberately out of scope for a first pass:
requiring a photo of the boarding pass/ticket for anything under the
reject line instead of just rejecting outright, and re-scoring a trip
already sitting at "pending" when a later traveller's submission would
have corroborated it.
"""

from datetime import date, datetime, timedelta, timezone

import airportsdata
import httpx

from . import aerodatabox, airlabs
from .schema import Flight, FlightStatus, flight_id

APPROVE_AT = 70
REJECT_BELOW = 20
TIME_TOLERANCE_MINUTES = 90

_AIRPORTS = airportsdata.load("IATA")


def _schedule_key(number: str, dep: str, arr: str) -> str:
    return f"{number.upper()}:{dep.upper()}-{arr.upper()}"


def _minutes(dt: datetime) -> int:
    return dt.hour * 60 + dt.minute


def _within_tolerance(a: int, b: int, tolerance: int = TIME_TOLERANCE_MINUTES) -> bool:
    """Minutes-since-midnight, wrapped across the day boundary — 23:50 and
    00:10 the "next" day are 20 minutes apart, not 1420."""
    diff = abs(a - b)
    return min(diff, 1440 - diff) <= tolerance


async def known_schedule(db, number: str, dep: str, arr: str,
                          dep_time: datetime | None = None, arr_time: datetime | None = None) -> dict | None:
    """A previously-approved fed flight's own record for this exact
    number+route, if the community has already confirmed one — and, when
    times are given to check against, they're close enough to be the same
    flight rather than a coincidental number reuse."""
    doc = await db.feed_schedules.find_one({"_id": _schedule_key(number, dep, arr)})
    if not doc:
        return None
    if dep_time is not None and not _within_tolerance(_minutes(dep_time), doc["departureMinutes"]):
        return None
    if arr_time is not None and not _within_tolerance(_minutes(arr_time), doc["arrivalMinutes"]):
        return None
    return doc


async def _remember(db, number: str, airline_name: str, dep: str, arr: str, dep_time: datetime, arr_time: datetime) -> None:
    now = datetime.now(timezone.utc)
    await db.feed_schedules.update_one(
        {"_id": _schedule_key(number, dep, arr)},
        {
            "$setOnInsert": {
                "flightNumber": number.upper(), "airlineName": airline_name,
                "departure": dep.upper(), "arrival": arr.upper(),
                "departureMinutes": _minutes(dep_time), "arrivalMinutes": _minutes(arr_time),
                "firstApprovedAt": now,
            },
            "$inc": {"sampleCount": 1},
            "$set": {"lastConfirmedAt": now},
        },
        upsert=True,
    )


async def schedule_for_search(db, number: str, day: date) -> Flight | None:
    """Every route this number has an approved community schedule for, as
    a best-guess Flight for the requested day — the same last resort a
    traveller's own manual entry would otherwise have to fill in by hand,
    now served automatically once at least one other traveller already
    has. Never live data, just the clock times an earlier approval
    established, rebased onto whatever day is asked for now — a real
    status source can still override this later, same as AirLabs' own
    plain-timetable rows already work."""
    cleaned = number.upper().replace(" ", "")
    docs = [d async for d in db.feed_schedules.find({"flightNumber": cleaned})]
    if not docs:
        return None
    # Most-corroborated first — if a number was ever reused for a second
    # route, this is the best guess for which one is still real.
    docs.sort(key=lambda d: d.get("sampleCount", 0), reverse=True)
    d = docs[0]
    base = datetime.combine(day, datetime.min.time())
    dep_dt = base.replace(hour=d["departureMinutes"] // 60, minute=d["departureMinutes"] % 60)
    arr_dt = base.replace(hour=d["arrivalMinutes"] // 60, minute=d["arrivalMinutes"] % 60)
    if arr_dt <= dep_dt:
        arr_dt += timedelta(days=1)  # an overnight flight's arrival lands the next calendar day
    return Flight(
        id=flight_id(cleaned, day), flightNumber=cleaned, airlineName=d.get("airlineName") or cleaned[:2],
        departure=d["departure"], arrival=d["arrival"], departureTime=dep_dt, arrivalTime=arr_dt,
        status=FlightStatus.SCHEDULED, source="feed",
    )


async def _schedule_confirms(client: httpx.AsyncClient, db, number: str, day: date, dep: str, arr: str,
                              dep_time: datetime | None, arr_time: datetime | None) -> bool:
    try:
        f = await airlabs.lookup(client, number, day)
        if f.departure == dep and f.arrival == arr:
            return True
    except Exception:
        pass
    try:
        candidates = await aerodatabox.flights(client, number, day)
        if any(c.departure == dep and c.arrival == arr for c in candidates):
            return True
    except Exception:
        pass
    return await known_schedule(db, number, dep, arr, dep_time, arr_time) is not None


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
    """Another traveller, not this one, has already fed the identical
    flight, on the same calendar day — clock-time differences (a delay,
    an early push-back) don't disqualify it, only the day matters here."""
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


async def score(http: httpx.AsyncClient, db, user_id, number: str, day: date, dep: str, arr: str,
                 dep_time: datetime | None = None, arr_time: datetime | None = None, airline_name: str = "") -> str:
    """The resolved feedStatus for a fresh manual entry — "approved",
    "rejected", or "pending". Never trust the client's own say-so for
    this: it always arrives as "pending" and this is what actually
    decides it, before the trip is ever stored. An approval also teaches
    this number+route to feed_schedules, for the next traveller."""
    total = 0
    if await _schedule_confirms(http, db, number, day, dep, arr, dep_time, arr_time):
        total += 50
    if await _adsbdb_confirms(http, number, dep, arr):
        total += 25
    if _airports_known(dep, arr):
        total += 10
    if await _corroborated(db, user_id, number, day.isoformat(), dep, arr):
        total += 30
    if total >= APPROVE_AT:
        if dep_time is not None and arr_time is not None:
            await _remember(db, number, airline_name, dep, arr, dep_time, arr_time)
        return "approved"
    if total < REJECT_BELOW:
        return "rejected"
    return "pending"
