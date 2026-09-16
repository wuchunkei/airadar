"""
The eight-tier status ladder, plus the hidden Rainbow tier above it — mirrors
Airadar/Models/MilestoneTier.swift band for band. The client computes its own
standing locally from its own cached trips (instant, no round trip); this
module exists for the one thing a client can never be trusted to award
itself: a Rainbow claim's sequence number, "the Nth traveller to get here",
which has to come from one shared, atomically-incremented counter.
"""

import math
from datetime import datetime, timezone

import airportsdata
from fastapi import APIRouter, Depends, HTTPException, Request

from .auth import current_user

router = APIRouter(prefix="/tiers", tags=["tiers"])

_AIRPORTS = airportsdata.load("IATA")
AVERAGE_KM_PER_LEG = 1157

# (name, lower bound, upper bound) — legs 1-10 are Black Iron, 11-20 Bronze,
# and so on; Rainbow, the true ceiling, has no upper bound.
BANDS: list[tuple[str, int, int | None]] = [
    ("blackIron", 1, 10),
    ("bronze", 11, 20),
    ("silver", 21, 30),
    ("gold", 31, 50),
    ("platinum", 51, 75),
    ("diamond", 76, 100),
    ("ruby", 101, 250),
    ("obsidian", 251, 499),
    ("rainbow", 500, None),
]


def _km(a: str, b: str) -> float:
    ra, rb = _AIRPORTS.get(a), _AIRPORTS.get(b)
    if not ra or not rb:
        return 0.0
    lat1, lon1, lat2, lon2 = map(math.radians, (ra["lat"], ra["lon"], rb["lat"], rb["lon"]))
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(h))


def standing(flights: list[dict]) -> str:
    """The same walk TierStanding.compute does in Swift: legs and km since
    the last rank-up, whichever hits the current tier's budget first
    promotes. Only the resulting tier name matters here — a claim just
    needs to know whether it's "rainbow" or not."""
    ordered = sorted(flights, key=lambda f: f["departureTime"])
    band_i = 0
    legs = km = 0
    for f in ordered:
        legs += 1
        km += _km(f["departure"], f["arrival"])
        while band_i + 1 < len(BANDS):
            _, lo, hi = BANDS[band_i]
            width = hi - lo + 1
            if legs >= width or km >= width * AVERAGE_KM_PER_LEG:
                band_i += 1
                legs = km = 0
            else:
                break
    return BANDS[band_i][0]


@router.post("/rainbow/claim")
async def claim_rainbow(request: Request, user: dict = Depends(current_user)):
    """Idempotent: a traveller who already claimed a rank just gets it back.
    Otherwise their own stored trips are re-walked server-side — never trust
    the client's own say-so for a rank that has to stay unique — and only a
    genuine Rainbow standing gets a number handed out."""
    db = request.app.state.db
    existing = await db.rainbow_claims.find_one({"_id": user["_id"]})
    if existing:
        return {"rank": existing["rank"]}

    cursor = db.trips.find({
        "userId": user["_id"], "deletedAt": None, "isPending": False,
        "departureTime": {"$lte": datetime.now(timezone.utc)},
    })
    flights = [d async for d in cursor]
    if standing(flights) != "rainbow":
        raise HTTPException(status_code=400, detail="Not at Rainbow yet.")

    counter = await db.counters.find_one_and_update(
        {"_id": "rainbow_rank"}, {"$inc": {"value": 1}}, upsert=True, return_document=True,
    )
    rank = counter["value"]
    await db.rainbow_claims.insert_one({"_id": user["_id"], "rank": rank, "achievedAt": datetime.now(timezone.utc)})
    return {"rank": rank}


@router.get("/rainbow/mine")
async def my_rainbow(request: Request, user: dict = Depends(current_user)):
    existing = await request.app.state.db.rainbow_claims.find_one({"_id": user["_id"]})
    return {"rank": existing["rank"] if existing else None}
