"""
A signed-in traveller's trips. Every query carries the user id, so one person's
list can never leak into another's.

The document id is "{userId}:{flightNumber}-{date}", so adding the same flight
twice is an update, not a duplicate. Deleting sets deletedAt; the recycle bin is
the set of documents that have it, and Mongo's TTL index empties it after
TRASH_RETENTION_DAYS.
"""

from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from . import airlabs, names
from .auth import current_user
from .billing import membership
from .schema import FlightStatus

router = APIRouter(prefix="/trips", tags=["trips"])


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
    callsign: str | None = None
    pnr: str | None = None
    isPending: bool = False
    # Entered by hand because no source knew the flight; shown with a warning block.
    isManual: bool = False
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


# What a live look-up may change on a stored trip; the rest is the traveller's.
LIVE_FIELDS = ("status", "delayMinutes", "departureTime", "arrivalTime", "departureTerminal", "arrivalTerminal",
               "departureGate", "arrivalGate", "baggageClaim", "aircraft", "callsign")
LIVE_WINDOW = timedelta(hours=36)   # around departure: from the day before to a while after landing
LIVE_EVERY = timedelta(minutes=5)   # per trip, so a list that is pulled often stays within quota


async def _refresh_live(state, doc: dict) -> dict:
    """Flights of the day get their status, gates and delay from AirLabs, at most every few minutes."""
    db = state.db
    dep = doc.get("departureTime")
    if not isinstance(dep, datetime) or doc.get("isManual"):
        return doc
    dep = dep.replace(tzinfo=None)
    now = _now().replace(tzinfo=None)
    if not (dep - LIVE_WINDOW <= now <= dep + LIVE_WINDOW):
        return doc
    checked = doc.get("liveCheckedAt")
    if isinstance(checked, datetime) and now - checked.replace(tzinfo=None) < LIVE_EVERY:
        return doc
    try:
        # The live record only: a timetable row knows nothing of today's delay and
        # would wipe one already stored.
        live = await airlabs.flight(state.http, doc["flightNumber"], dep.date())
        if live.departureTime.date() != dep.date():
            raise airlabs.AirLabsError("live record is for another day")
    except Exception:
        # A miss is not news; try again after the same interval.
        await db.trips.update_one({"_id": doc["_id"]}, {"$set": {"liveCheckedAt": now}})
        return doc
    fresh = live.model_dump()
    changes = {k: fresh[k] for k in LIVE_FIELDS if fresh.get(k) is not None and fresh[k] != doc.get(k)}
    if isinstance(changes.get("status"), FlightStatus):
        changes["status"] = changes["status"].value
    changes["liveCheckedAt"] = now
    await db.trips.update_one({"_id": doc["_id"]}, {"$set": changes})
    return {**doc, **changes}


@router.get("", response_model=list[Trip])
async def list_trips(request: Request, user: dict = Depends(current_user)):
    state = request.app.state
    cursor = state.db.trips.find({"userId": user["_id"], "deletedAt": None})
    docs = [d async for d in cursor]
    return [_out(await _refresh_live(state, d)) for d in docs]


@router.get("/deleted", response_model=list[Trip])
async def list_deleted(request: Request, user: dict = Depends(current_user)):
    cursor = request.app.state.db.trips.find({"userId": user["_id"], "deletedAt": {"$ne": None}})
    return [_out(d) async for d in cursor]


async def _enforce_limits(db, user: dict, trip: TripIn, key: str) -> None:
    """
    Superior: 5 past trips, 10 ahead (Now + Coming), nothing beyond a month out.
    Guest-level (lapsed): 1 past trip, a week ahead, 3 trips in all.
    Premium: no limits. Updating a trip that already exists is always allowed.
    """
    m = await membership(db, user)
    lim = m.limits
    if lim.maxPastTrips is None and lim.futureDays is None and lim.maxTrips is None and lim.maxUpcomingTrips is None:
        return
    if await db.trips.find_one({"_id": key, "deletedAt": None}):
        return
    today = date.today()
    trip_day = trip.departureTime.date()
    cursor = db.trips.find({"userId": user["_id"], "deletedAt": None})
    existing = [d async for d in cursor]
    past_count = sum(1 for d in existing if d["departureTime"].date() < today)
    upcoming_count = len(existing) - past_count  # today and ahead: Now and Coming

    def refuse(reason: str):
        raise HTTPException(status_code=402, detail={"code": "limit", "tier": m.tier, "error": reason})

    if lim.maxTrips is not None and len(existing) >= lim.maxTrips:
        refuse(f"{lim.maxTrips} trips is the most this plan keeps.")
    if trip_day < today and lim.maxPastTrips is not None and past_count >= lim.maxPastTrips:
        refuse(f"This plan keeps {lim.maxPastTrips} past trip{'s' if lim.maxPastTrips != 1 else ''}.")
    if trip_day >= today and lim.maxUpcomingTrips is not None and upcoming_count >= lim.maxUpcomingTrips:
        refuse(f"This plan keeps {lim.maxUpcomingTrips} trips ahead at a time.")
    if trip_day > today and lim.futureDays is not None and (trip_day - today).days > lim.futureDays:
        refuse(f"This plan adds trips up to {lim.futureDays} days ahead.")


@router.put("/{trip_id}", response_model=Trip)
async def put_trip(trip_id: str, trip: TripIn, request: Request, user: dict = Depends(current_user)):
    if trip.id != trip_id:
        raise HTTPException(status_code=400, detail="Body id does not match the path.")
    await _enforce_limits(request.app.state.db, user, trip, _key(user, trip_id))
    now = _now()
    doc = await request.app.state.db.trips.find_one_and_update(
        {"_id": _key(user, trip_id)},
        {
            "$set": {**_store(trip), "userId": user["_id"], "updatedAt": now, "deletedAt": None},
            "$setOnInsert": {"createdAt": now},
        },
        upsert=True,
        return_document=True,
    )
    await names.auto_share_for_trip(request.app.state.db, user, doc)
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
