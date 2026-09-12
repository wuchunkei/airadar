"""
A signed-in traveller's trips. Every query carries the user id, so one person's
list can never leak into another's.

The document id is "{userId}:{flightNumber}-{date}", so adding the same flight
twice is an update, not a duplicate. Deleting sets deletedAt; the recycle bin is
the set of documents that have it, and Mongo's TTL index empties it after
TRASH_RETENTION_DAYS.
"""

from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from .auth import current_user
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


@router.get("", response_model=list[Trip])
async def list_trips(request: Request, user: dict = Depends(current_user)):
    cursor = request.app.state.db.trips.find({"userId": user["_id"], "deletedAt": None})
    return [_out(d) async for d in cursor]


@router.get("/deleted", response_model=list[Trip])
async def list_deleted(request: Request, user: dict = Depends(current_user)):
    cursor = request.app.state.db.trips.find({"userId": user["_id"], "deletedAt": {"$ne": None}})
    return [_out(d) async for d in cursor]


@router.put("/{trip_id}", response_model=Trip)
async def put_trip(trip_id: str, trip: TripIn, request: Request, user: dict = Depends(current_user)):
    if trip.id != trip_id:
        raise HTTPException(status_code=400, detail="Body id does not match the path.")
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
