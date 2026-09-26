"""
A signed-in traveller's trips. Every query carries the user id, so one person's
list can never leak into another's.

The document id is "{userId}:{flightNumber}-{date}", so adding the same flight
twice is an update, not a duplicate. Deleting sets deletedAt; the recycle bin is
the set of documents that have it, and Mongo's TTL index empties it after
TRASH_RETENTION_DAYS.
"""

from datetime import date, datetime, timedelta, timezone
from enum import Enum
from zoneinfo import ZoneInfo

import airportsdata

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from . import airlabs, airportboard, feed, names
from .auth import current_user
from .billing import membership
from .schema import FlightStatus

router = APIRouter(prefix="/trips", tags=["trips"])


class FeedStatus(str, Enum):
    """A manually-entered flight's verification outcome — see feed.py for
    the automated scoring and community.py for the crowd review a
    "pending" result then goes to. The client only ever sends PENDING for
    a fresh entry; this is what the server actually resolves it to."""
    PENDING = "pending"
    APPROVED = "approved"
    REJECTED = "rejected"
    EXPIRED = "expired"


class TripIn(BaseModel):
    """Exactly the app's Flight, minus the derived fields."""
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
    arrivalDelayMinutes: int | None = None
    # From the departure airport's own board, around departure — see airportboard.py.
    boardingStatus: str | None = None
    # What a gate or belt read before it last changed, so the apps can show the
    # old one struck through beside the new.
    departureGatePrevious: str | None = None
    arrivalGatePrevious: str | None = None
    baggageClaimPrevious: str | None = None
    callsign: str | None = None
    pnr: str | None = None
    isPending: bool = False
    # Entered by hand because no source knew the flight; shown with a warning block.
    isManual: bool = False
    # Set only on a flight fed this way — see feed.py for how it's resolved.
    feedStatus: FeedStatus | None = None
    # Names found on the ticket text this trip was imported from; drives automatic sharing.
    passengers: list[str] = []
    track: list[list[float]] | None = None
    trackFlownOn: date | None = None


class Trip(TripIn):
    deletedAt: datetime | None = None
    updatedAt: datetime


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _key(user: dict, trip_id: str) -> str:
    return f"{user['_id']}:{trip_id}"


def _out(doc: dict) -> Trip:
    doc = {k: v for k, v in doc.items() if k not in ("_id", "userId")}
    if doc.get("trackFlownOn") is not None and isinstance(doc["trackFlownOn"], datetime):
        doc["trackFlownOn"] = doc["trackFlownOn"].date()
    return Trip(**doc)


def _store(trip: TripIn) -> dict:
    doc = trip.model_dump()
    # Mongo has no date type; a midnight datetime stands in for the calendar day.
    if doc.get("trackFlownOn") is not None:
        doc["trackFlownOn"] = datetime.combine(doc["trackFlownOn"], datetime.min.time())
    return doc


REVIEW_WINDOW = timedelta(days=7)
REVIEW_FIRST_TARGET = 10


async def apply_feed_status(db, trip_key: str, status: str) -> None:
    """Pushes a community review's resolved verdict onto the matching trip
    document — called from community.py once voting or an admin override
    resolves a review. The automated feed.py path doesn't need this: it
    writes feedStatus directly into `store` before the trip is ever
    inserted, in put_trip below."""
    await db.trips.update_one({"_id": trip_key}, {"$set": {"feedStatus": status, "updatedAt": _now()}})


# What a live look-up may change on a stored trip; the rest is the traveller's.
LIVE_FIELDS = ("status", "delayMinutes", "arrivalDelayMinutes", "departureTime", "arrivalTime", "departureTerminal", "arrivalTerminal",
               "departureGate", "arrivalGate", "baggageClaim", "aircraft", "callsign")
LIVE_WINDOW = timedelta(hours=36)   # around departure: from the day before to a while after landing
# How stale a flight's live record may get before AirLabs is asked again. Tight
# while a delay matters most, from a few hours before take-off until just after
# landing; loose the rest of the window, where a delay a day out can wait.
LIVE_HOT_EVERY = timedelta(minutes=2)
LIVE_EVERY = timedelta(minutes=10)
HOT_BEFORE = timedelta(hours=3)
HOT_AFTER = timedelta(minutes=30)
LIVE_CACHE_TTL = timedelta(days=3)
# Bumped whenever the live record gains a field, so a record cached by an
# older build (which would read as "no change" for the new field) is refetched
# at once instead of lingering until its interval runs out.
LIVE_CACHE_VERSION = 2


_AIRPORTS = airportsdata.load("IATA")


def _utc(local: datetime, iata: str | None) -> datetime:
    """A stored time — the airport's own wall clock, as the sources give it — as
    naive UTC, to compare with the server's clock. Left as is for an airport
    with no known zone."""
    local = local.replace(tzinfo=None)
    tz = (_AIRPORTS.get(iata or "") or {}).get("tz")
    if not tz:
        return local
    return local.replace(tzinfo=ZoneInfo(tz)).astimezone(timezone.utc).replace(tzinfo=None)


def _live_interval(doc: dict, now: datetime) -> timedelta:
    """`now` is naive UTC."""
    dep = _utc(doc["departureTime"], doc.get("departure"))
    arr = doc.get("arrivalTime")
    arr = _utc(arr, doc.get("arrival")) if isinstance(arr, datetime) else dep
    dep_delay = timedelta(minutes=doc.get("delayMinutes") or 0)
    arr_moved = doc.get("arrivalDelayMinutes")
    arr_delay = timedelta(minutes=arr_moved) if arr_moved is not None else dep_delay
    return LIVE_HOT_EVERY if dep + dep_delay - HOT_BEFORE <= now <= arr + arr_delay + HOT_AFTER else LIVE_EVERY


async def _live_record(state, number: str, day: date, every: timedelta, now: datetime) -> dict | None:
    """AirLabs' live record for one flight on one day, shared by every traveller
    on it: one look-up per interval however many trips point at the flight. None
    when AirLabs has nothing for it (also cached, so a miss isn't retried sooner)."""
    key = f"{number.upper()}:{day.isoformat()}"
    cached = await state.db.live_cache.find_one({"_id": key})
    if cached and cached.get("version") == LIVE_CACHE_VERSION and now - cached["fetchedAt"].replace(tzinfo=None) < every:
        return cached.get("flight")
    try:
        # The live record only: a timetable row knows nothing of today's delay and
        # would wipe one already stored.
        live = await airlabs.flight(state.http, number, day)
        if live.departureTime.date() != day:
            raise airlabs.AirLabsError("live record is for another day")
        record = live.model_dump()
        if isinstance(record.get("status"), FlightStatus):
            record["status"] = record["status"].value
    except Exception:
        record = None
    await state.db.live_cache.update_one(
        {"_id": key},
        {"$set": {"flight": record, "fetchedAt": now, "expiresAt": now + LIVE_CACHE_TTL, "version": LIVE_CACHE_VERSION}},
        upsert=True,
    )
    return record


async def _refresh_live(state, doc: dict) -> dict:
    """Flights of the day get their status, gates and delay from AirLabs: every
    couple of minutes around the flight itself, less often further out."""
    dep = doc.get("departureTime")
    if not isinstance(dep, datetime) or doc.get("isManual"):
        return doc
    dep = dep.replace(tzinfo=None)
    now = _now().replace(tzinfo=None)
    dep_utc = _utc(dep, doc.get("departure"))
    if not (dep_utc - LIVE_WINDOW <= now <= dep_utc + LIVE_WINDOW):
        return doc
    # AirLabs keys a flight by its local departure date.
    fresh = await _live_record(state, doc["flightNumber"], dep.date(), _live_interval(doc, now), now)
    changes = {k: fresh[k] for k in LIVE_FIELDS if fresh.get(k) is not None and fresh[k] != doc.get(k)} if fresh else {}
    changes.update(await _boarding_changes(state, doc, dep, dep_utc, now))
    # The arrival airport's own board has the landing first and gets it right;
    # applied last, so it has the final word over the flight API's estimate.
    changes.update(await _arrival_changes(state, {**doc, **changes}, dep_utc, now))
    _note_previous(doc, changes)
    if not changes:
        return doc
    await state.db.trips.update_one({"_id": doc["_id"]}, {"$set": changes})
    return {**doc, **changes}


def _note_previous(doc: dict, changes: dict) -> None:
    """A gate or belt that moved from one real value to another keeps the old
    one alongside, for the apps to strike through."""
    for key in ("departureGate", "arrivalGate", "baggageClaim"):
        old, new = doc.get(key), changes.get(key)
        if old and new and new != old:
            changes[f"{key}Previous"] = old


# The departure airport's board is only asked about while it can say something
# useful: from check-in opening to a while after the scheduled departure.
BOARD_BEFORE = timedelta(hours=3)
BOARD_AFTER = timedelta(hours=1)


async def _boarding_changes(state, doc: dict, dep_local: datetime, dep_utc: datetime, now: datetime) -> dict:
    """Boarding progress (and the gate, which the airport's own board knows
    first) for a departure from an airport that publishes it."""
    airport = doc.get("departure")
    if airport not in airportboard.AIRPORTS or not (dep_utc - BOARD_BEFORE <= now <= dep_utc + BOARD_AFTER):
        return {}
    found = await airportboard.lookup(state.http, airport, doc["flightNumber"], dep_local)
    if found is None:
        return {}
    phase, gate = found
    changes = {}
    if phase != doc.get("boardingStatus"):
        changes["boardingStatus"] = phase
    if gate and gate != doc.get("departureGate"):
        changes["departureGate"] = gate
    return changes


# The arrival airport's board is asked from take-off until a while after the
# timetabled landing — enough for a late one, and for the belt to be posted.
ARRIVAL_AFTER = timedelta(hours=3)


async def _arrival_changes(state, doc: dict, dep_utc: datetime, now: datetime) -> dict:
    """When the flight actually landed (or is now expected), its arrival gate
    and belt, for an arrival at an airport that publishes them."""
    airport, arr = doc.get("arrival"), doc.get("arrivalTime")
    if airport not in airportboard.AIRPORTS or not isinstance(arr, datetime):
        return {}
    arr = arr.replace(tzinfo=None)
    if not (dep_utc <= now <= _utc(arr, airport) + ARRIVAL_AFTER):
        return {}
    found = await airportboard.lookup_arrival(state.http, airport, doc["flightNumber"], arr)
    if found is None:
        return {}
    changes = {}
    moved = found.landed or (found.expected if doc.get("status") != FlightStatus.LANDED.value else None)
    if moved is not None:
        minutes = round((moved - arr).total_seconds() / 60)
        if minutes != doc.get("arrivalDelayMinutes"):
            changes["arrivalDelayMinutes"] = minutes
    if found.landed and doc.get("status") != FlightStatus.LANDED.value:
        changes["status"] = FlightStatus.LANDED.value
    if found.gate and found.gate != doc.get("arrivalGate"):
        changes["arrivalGate"] = found.gate
    if found.belt and found.belt != doc.get("baggageClaim"):
        changes["baggageClaim"] = found.belt
    return changes


@router.get("", response_model=list[Trip])
async def list_trips(request: Request, user: dict = Depends(current_user)):
    state = request.app.state
    db = state.db
    cursor = db.trips.find({"userId": user["_id"], "deletedAt": None})
    docs = [d async for d in cursor]
    lim = (await membership(db, user)).limits
    if lim.pastDays is not None:
        # A guest's sync reaches PAST_DAYS back, not further -- a trip older
        # than that just stops appearing, the same as if it had never
        # synced; nothing about the stored document itself changes; it
        # reappears the moment the plan does.
        cutoff = date.today() - timedelta(days=lim.pastDays)
        docs = [d for d in docs if d["departureTime"].date() >= cutoff]
    return [_out(await _refresh_live(state, d)) for d in docs]


@router.get("/deleted", response_model=list[Trip])
async def list_deleted(request: Request, user: dict = Depends(current_user)):
    cursor = request.app.state.db.trips.find({"userId": user["_id"], "deletedAt": {"$ne": None}})
    return [_out(d) async for d in cursor]


async def _enforce_limits(db, user: dict, trip: TripIn, key: str) -> None:
    """
    Guest: one trip in the air or ahead at a time, and a past trip only
    within PAST_DAYS back. Premium: no limits. Updating a trip that already
    exists is always allowed -- these gate new trips only.
    """
    m = await membership(db, user)
    lim = m.limits
    if lim.maxUpcomingTrips is None and lim.pastDays is None and lim.futureDays is None:
        return
    if await db.trips.find_one({"_id": key, "deletedAt": None}):
        return
    today = date.today()
    trip_day = trip.departureTime.date()

    def refuse(reason: str):
        raise HTTPException(status_code=402, detail={"code": "limit", "tier": m.tier, "error": reason})

    if trip_day < today and lim.pastDays is not None and (today - trip_day).days > lim.pastDays:
        refuse(f"This plan adds past trips up to {lim.pastDays} days back.")
    if trip_day > today and lim.futureDays is not None and (trip_day - today).days > lim.futureDays:
        refuse(f"This plan adds trips up to {lim.futureDays} days ahead.")
    if trip_day >= today and lim.maxUpcomingTrips is not None:
        cursor = db.trips.find({"userId": user["_id"], "deletedAt": None})
        upcoming_count = sum(1 async for d in cursor if d["departureTime"].date() >= today)
        if upcoming_count >= lim.maxUpcomingTrips:
            refuse(f"This plan keeps {lim.maxUpcomingTrips} trip{'s' if lim.maxUpcomingTrips != 1 else ''} ahead at a time.")


@router.put("/{trip_id}", response_model=Trip)
async def put_trip(trip_id: str, trip: TripIn, request: Request, user: dict = Depends(current_user)):
    if trip.id != trip_id:
        raise HTTPException(status_code=400, detail="Body id does not match the path.")
    db = request.app.state.db
    key = _key(user, trip_id)
    await _enforce_limits(db, user, trip, key)
    now = _now()
    store = _store(trip)
    # A fresh fed flight — never stored before, still marked pending by the
    # client — gets scored here first, so the traveller's own Trip card
    # already carries the resolved outcome, not the client's own guess.
    if trip.isManual and trip.feedStatus == FeedStatus.PENDING and not await db.trips.find_one({"_id": key}):
        resolved = await feed.score(request.app.state.http, db, user["_id"], trip.flightNumber,
                                     trip.departureTime.date(), trip.departure, trip.arrival,
                                     dep_time=trip.departureTime, arr_time=trip.arrivalTime,
                                     airline_name=trip.airlineName)
        store["feedStatus"] = resolved
        # The automated scorer couldn't settle it either way — hand it to
        # the community instead of leaving it stuck at "pending" forever.
        # upsert + $setOnInsert: idempotent if this ever ran twice for the
        # same still-nonexistent trip.
        if resolved == "pending":
            await db.feed_reviews.update_one(
                {"_id": key},
                {"$setOnInsert": {
                    "ownerId": user["_id"],
                    "flightNumber": trip.flightNumber, "airlineName": trip.airlineName,
                    "departure": trip.departure, "arrival": trip.arrival,
                    "departureTime": trip.departureTime, "arrivalTime": trip.arrivalTime,
                    "status": "pending", "targetVotes": REVIEW_FIRST_TARGET, "noThreshold": False, "boosted": False,
                    "deadline": now + REVIEW_WINDOW, "createdAt": now, "resolvedAt": None, "adminOverride": False,
                }},
                upsert=True,
            )
    doc = await db.trips.find_one_and_update(
        {"_id": key},
        {
            "$set": {**store, "userId": user["_id"], "updatedAt": now, "deletedAt": None},
            "$setOnInsert": {"createdAt": now},
        },
        upsert=True,
        return_document=True,
    )
    await names.auto_share_for_trip(db, user, doc)
    return _out(doc)


@router.delete("/{trip_id}", response_model=Trip)
async def delete_trip(trip_id: str, request: Request, user: dict = Depends(current_user)):
    doc = await request.app.state.db.trips.find_one_and_update(
        {"_id": _key(user, trip_id), "userId": user["_id"]},
        {"$set": {"deletedAt": _now(), "updatedAt": _now()}},
        return_document=True,
    )
    if not doc:
        raise HTTPException(status_code=404, detail="No such trip.")
    return _out(doc)


@router.post("/{trip_id}/restore", response_model=Trip)
async def restore_trip(trip_id: str, request: Request, user: dict = Depends(current_user)):
    doc = await request.app.state.db.trips.find_one_and_update(
        {"_id": _key(user, trip_id), "userId": user["_id"]},
        {"$set": {"deletedAt": None, "updatedAt": _now()}},
        return_document=True,
    )
    if not doc:
        raise HTTPException(status_code=404, detail="No such trip.")
    return _out(doc)
