"""
Passenger names: who a trip is for, and the automatic sharing that follows.

A traveller may confirm the name their Google account carries (or type the one on
their tickets). It is used for one thing — recognising which imported flights are
theirs, and letting friends recognise them — never for anything else.

Names come in many shapes: "WU/CHUNKEI", "MR CHUN KEI WU", "Chun Kei Wu". They
match when every token of the traveller's name is found in the candidate's letters
and nothing much is left over.
"""

import re
from datetime import datetime, timezone

TITLES = {"MR", "MRS", "MS", "MISS", "DR", "MSTR", "MASTER"}


def normalize(name: str) -> str:
    """Letters only, upper-case, titles dropped."""
    words = [w for w in re.split(r"[^A-Za-z]+", name.upper()) if w and w not in TITLES]
    return "".join(words)


def tokens(name: str) -> list[str]:
    return [w for w in re.split(r"[^A-Za-z]+", name.upper()) if w and w not in TITLES]


def same_person(mine: str, candidate: str) -> bool:
    """Every token of `mine` appears in the candidate's letters, with at most two letters spare."""
    mine_tokens = tokens(mine)
    cand = normalize(candidate)
    if not mine_tokens or not cand:
        return False
    if not all(t in cand for t in mine_tokens):
        return False
    return len(cand) - sum(len(t) for t in mine_tokens) <= 2


def _now() -> datetime:
    return datetime.now(timezone.utc)


async def _friend_ids(db, user_id) -> list:
    rows = db.friendships.find({"$or": [{"a": user_id}, {"b": user_id}], "status": "accepted"})
    return [r["b"] if r["a"] == user_id else r["a"] async for r in rows]


async def _ensure_share(db, owner: dict, trip_doc: dict, to_id, status: str) -> None:
    """A friend share, created if absent; an existing one is left as it stands."""
    if await db.shares.find_one({"tripKey": trip_doc["_id"], "toUserId": to_id}):
        return
    await db.shares.insert_one({
        "tripKey": trip_doc["_id"], "tripId": trip_doc["id"], "ownerId": owner["_id"], "toUserId": to_id,
        "kind": "friend", "status": status, "auto": True, "createdAt": _now(),
    })


async def auto_share_for_trip(db, user: dict, trip_doc: dict) -> None:
    """
    Called after a trip is saved. Two cases:
      - a friend already holds the same flight → both see each other's copy as "together";
      - a name on the ticket is a friend's → they get the trip as shared, to accept or take together.
    """
    friend_ids = await _friend_ids(db, user["_id"])
    if not friend_ids:
        return
    friends = [f async for f in db.users.find({"_id": {"$in": friend_ids}})]

    same_flight = db.trips.find({
        "userId": {"$in": friend_ids}, "deletedAt": None,
        "flightNumber": trip_doc["flightNumber"], "departureTime": trip_doc["departureTime"],
    })
    async for theirs in same_flight:
        owner = next((f for f in friends if f["_id"] == theirs["userId"]), None)
        if owner is None:
            continue
        await _ensure_share(db, owner, theirs, user["_id"], "together")
        await _ensure_share(db, user, trip_doc, owner["_id"], "together")

    for name in trip_doc.get("passengers") or []:
        for f in friends:
            pn = f.get("passengerName")
            if pn and same_person(pn, name):
                await _ensure_share(db, user, trip_doc, f["_id"], "accepted")


async def auto_share_for_name(db, user: dict) -> None:
    """Called when a traveller sets their name: friends' trips carrying it are shared to them."""
    pn = user.get("passengerName")
    if not pn:
        return
    friend_ids = await _friend_ids(db, user["_id"])
    if not friend_ids:
        return
    rows = db.trips.find({"userId": {"$in": friend_ids}, "deletedAt": None, "passengers": {"$exists": True, "$ne": []}})
    async for t in rows:
        if any(same_person(pn, n) for n in t.get("passengers") or []):
            owner = await db.users.find_one({"_id": t["userId"]})
            if owner:
                await _ensure_share(db, owner, t, user["_id"], "accepted")
