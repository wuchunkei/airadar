"""
Friends and shared trips.

friendships — one document per pair, keyed "{lowerId}:{higherId}" so a pair can
only ever exist once; status pending → accepted. Finding someone's friends is one
indexed query on either side, however many they have.

shares — one document per (trip, recipient). A friend share lands on the
recipient's Trip page for them to accept, reject, or take "together" (a copy of
the trip goes into their own list). A link share has a token instead of a
recipient; whoever opens it may copy the trip, and no block is shown for it.
"""

import os
import secrets
from datetime import datetime, timezone

from bson import ObjectId
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

from .auth import current_user
from .billing import Membership, membership
from .db import PALETTE
from .trips import Trip, _out as trip_out

router = APIRouter(tags=["social"])


def _now() -> datetime:
    return datetime.now(timezone.utc)


def public_url(request: Request) -> str:
    """Where links should point: PUBLIC_URL once TLS and a domain exist, else this server as reached."""
    return os.environ.get("PUBLIC_URL", "").strip().rstrip("/") or str(request.base_url).rstrip("/")


def _given_name(user: dict) -> str:
    return user.get("givenName") or (user.get("name") or user["email"]).split(" ")[0].split("@")[0]


def _color(user: dict) -> str:
    return user.get("color") or PALETTE[int(str(user["_id"])[-2:], 16) % len(PALETTE)]


class Person(BaseModel):
    id: str
    givenName: str
    color: str


def _person(user: dict) -> Person:
    return Person(id=str(user["_id"]), givenName=_given_name(user), color=_color(user))


# ---- profile --------------------------------------------------------------------


class Me(Person):
    email: str
    name: str | None
    avatarUrl: str | None
    findableByEmail: bool
    membership: Membership


class ProfilePatch(BaseModel):
    """The colour is dealt at sign-up and never changes; only findability is the traveller's to set."""
    findableByEmail: bool | None = None


def _me(user: dict) -> Me:
    p = _person(user)
    return Me(
        **p.model_dump(),
        email=user["email"],
        name=user.get("name"),
        avatarUrl=user.get("avatarUrl"),
        findableByEmail=bool(user.get("findableByEmail", False)),
        membership=membership(user),
    )


@router.get("/me", response_model=Me)
async def me(user: dict = Depends(current_user)):
    return _me(user)


@router.patch("/me", response_model=Me)
async def patch_me(body: ProfilePatch, request: Request, user: dict = Depends(current_user)):
    changes = {k: v for k, v in body.model_dump().items() if v is not None}
    if changes:
        user = await request.app.state.db.users.find_one_and_update(
            {"_id": user["_id"]}, {"$set": changes}, return_document=True
        )
    return _me(user)


@router.get("/users/lookup", response_model=Person)
async def lookup(email: str, request: Request, user: dict = Depends(current_user)):
    """Only people who switched on "findable by email" can be found this way."""
    found = await request.app.state.db.users.find_one({"email": email.strip().lower(), "findableByEmail": True})
    if not found or found["_id"] == user["_id"]:
        raise HTTPException(status_code=404, detail="No one with that email is findable.")
    return _person(found)


# ---- friends ----------------------------------------------------------------------


class Friend(BaseModel):
    friendshipId: str
    person: Person
    status: str  # "accepted" | "incoming" | "outgoing"


class FriendRequest(BaseModel):
    userId: str


def _pair_key(a: ObjectId, b: ObjectId) -> str:
    x, y = sorted([str(a), str(b)])
    return f"{x}:{y}"


@router.get("/friends", response_model=list[Friend])
async def list_friends(request: Request, user: dict = Depends(current_user)):
    db = request.app.state.db
    me_id = user["_id"]
    rows = [r async for r in db.friendships.find({"$or": [{"a": me_id}, {"b": me_id}]})]
    other_ids = [r["b"] if r["a"] == me_id else r["a"] for r in rows]
    people = {u["_id"]: u async for u in db.users.find({"_id": {"$in": other_ids}})}
    out = []
    for r in rows:
        other = people.get(r["b"] if r["a"] == me_id else r["a"])
        if not other:
            continue
        status = "accepted" if r["status"] == "accepted" else ("outgoing" if r["requestedBy"] == me_id else "incoming")
        out.append(Friend(friendshipId=r["_id"], person=_person(other), status=status))
    order = {"incoming": 0, "accepted": 1, "outgoing": 2}
    return sorted(out, key=lambda f: (order[f.status], f.person.givenName.lower()))


@router.post("/friends/request", response_model=Friend)
async def request_friend(body: FriendRequest, request: Request, user: dict = Depends(current_user)):
    db = request.app.state.db
    other_id = ObjectId(body.userId)
    if not membership(user).limits.sharing:
        raise HTTPException(status_code=402, detail={"code": "limit", "tier": "guest", "error": "Friends need a subscription."})
    if other_id == user["_id"]:
        raise HTTPException(status_code=400, detail="That is you.")
    other = await db.users.find_one({"_id": other_id})
    if not other:
        raise HTTPException(status_code=404, detail="No such person.")
    key = _pair_key(user["_id"], other_id)
    existing = await db.friendships.find_one({"_id": key})
    if existing:
        # The other side already asked: that counts as both saying yes.
        if existing["status"] == "pending" and existing["requestedBy"] != user["_id"]:
            existing = await db.friendships.find_one_and_update(
                {"_id": key}, {"$set": {"status": "accepted", "acceptedAt": _now()}}, return_document=True
            )
        status = "accepted" if existing["status"] == "accepted" else "outgoing"
        return Friend(friendshipId=key, person=_person(other), status=status)
    await db.friendships.insert_one({
        "_id": key, "a": min(user["_id"], other_id), "b": max(user["_id"], other_id),
        "status": "pending", "requestedBy": user["_id"], "createdAt": _now(),
    })
    return Friend(friendshipId=key, person=_person(other), status="outgoing")


@router.post("/friends/{friendship_id}/accept", response_model=Friend)
async def accept_friend(friendship_id: str, request: Request, user: dict = Depends(current_user)):
    db = request.app.state.db
    row = await db.friendships.find_one_and_update(
        {"_id": friendship_id, "status": "pending", "requestedBy": {"$ne": user["_id"]},
         "$or": [{"a": user["_id"]}, {"b": user["_id"]}]},
        {"$set": {"status": "accepted", "acceptedAt": _now()}},
        return_document=True,
    )
    if not row:
        raise HTTPException(status_code=404, detail="No such request.")
    other = await db.users.find_one({"_id": row["b"] if row["a"] == user["_id"] else row["a"]})
    return Friend(friendshipId=friendship_id, person=_person(other), status="accepted")


@router.delete("/friends/{friendship_id}", status_code=204)
async def remove_friend(friendship_id: str, request: Request, user: dict = Depends(current_user)):
    """Declines a request or ends a friendship; either side may."""
    await request.app.state.db.friendships.delete_one(
        {"_id": friendship_id, "$or": [{"a": user["_id"]}, {"b": user["_id"]}]}
    )


async def _are_friends(db, a: ObjectId, b: ObjectId) -> bool:
    row = await db.friendships.find_one({"_id": _pair_key(a, b)})
    return bool(row and row["status"] == "accepted")


# ---- shares -------------------------------------------------------------------------


class ShareRequest(BaseModel):
    toUserId: str | None = None  # a friend
    # With no recipient a link is minted instead.


class Share(BaseModel):
    id: str
    tripId: str
    status: str  # pending | accepted | rejected | together
    kind: str  # friend | link
    token: str | None = None
    url: str | None = None  # the shareable link, for link shares
    person: Person | None = None  # the other party, as seen from the caller
    createdAt: datetime


class IncomingShare(Share):
    trip: Trip


class Respond(BaseModel):
    action: str  # accept | reject | together


def _share_out(doc: dict, person: dict | None, base: str | None = None) -> Share:
    token = doc.get("token")
    return Share(
        id=str(doc["_id"]), tripId=doc["tripId"], status=doc["status"], kind=doc["kind"],
        token=token, url=f"{base}/s/{token}" if token and base else None,
        person=_person(person) if person else None, createdAt=doc["createdAt"],
    )


@router.post("/trips/{trip_id}/share", response_model=Share)
async def share_trip(trip_id: str, body: ShareRequest, request: Request, user: dict = Depends(current_user)):
    db = request.app.state.db
    trip = await db.trips.find_one({"_id": f"{user['_id']}:{trip_id}", "deletedAt": None})
    if not trip:
        raise HTTPException(status_code=404, detail="No such trip.")

    if not membership(user).limits.sharing:
        raise HTTPException(status_code=402, detail={"code": "limit", "tier": "guest", "error": "Sharing needs a subscription."})
    if body.toUserId:
        to_id = ObjectId(body.toUserId)
        if not await _are_friends(db, user["_id"], to_id):
            raise HTTPException(status_code=403, detail="You can only share directly with friends.")
        existing = await db.shares.find_one({"tripKey": trip["_id"], "toUserId": to_id})
        if existing:
            other = await db.users.find_one({"_id": to_id})
            return _share_out(existing, other)
        doc = {"tripKey": trip["_id"], "tripId": trip_id, "ownerId": user["_id"], "toUserId": to_id,
               "kind": "friend", "status": "pending", "createdAt": _now()}
        await db.shares.insert_one(doc)
        other = await db.users.find_one({"_id": to_id})
        return _share_out(doc, other)

    existing = await db.shares.find_one({"tripKey": trip["_id"], "kind": "link"})
    if existing:
        return _share_out(existing, None, public_url(request))
    doc = {"tripKey": trip["_id"], "tripId": trip_id, "ownerId": user["_id"], "kind": "link",
           "token": secrets.token_urlsafe(12), "status": "accepted", "createdAt": _now()}
    await db.shares.insert_one(doc)
    return _share_out(doc, None, public_url(request))


@router.get("/shares/outgoing", response_model=list[Share])
async def outgoing(request: Request, user: dict = Depends(current_user)):
    """Friend shares of my trips, with each recipient and where they stand."""
    db = request.app.state.db
    rows = [r async for r in db.shares.find({"ownerId": user["_id"], "kind": "friend"})]
    people = {u["_id"]: u async for u in db.users.find({"_id": {"$in": [r["toUserId"] for r in rows]}})}
    return [_share_out(r, people.get(r["toUserId"])) for r in rows if r["toUserId"] in people]


@router.get("/shares/incoming", response_model=list[IncomingShare])
async def incoming(request: Request, user: dict = Depends(current_user)):
    """Friends' trips shared with me that I have not rejected, each with the trip as it is now."""
    db = request.app.state.db
    rows = [r async for r in db.shares.find({"toUserId": user["_id"], "status": {"$in": ["pending", "accepted", "together"]}})]
    owners = {u["_id"]: u async for u in db.users.find({"_id": {"$in": [r["ownerId"] for r in rows]}})}
    out = []
    for r in rows:
        trip = await db.trips.find_one({"_id": r["tripKey"], "deletedAt": None})
        owner = owners.get(r["ownerId"])
        if trip and owner:
            out.append(IncomingShare(**_share_out(r, owner).model_dump(), trip=trip_out(trip)))
    return out


@router.post("/shares/{share_id}/respond", response_model=Share)
async def respond(share_id: str, body: Respond, request: Request, user: dict = Depends(current_user)):
    db = request.app.state.db
    if body.action not in ("accept", "reject", "together"):
        raise HTTPException(status_code=400, detail="action must be accept, reject or together.")
    share = await db.shares.find_one({"_id": ObjectId(share_id), "toUserId": user["_id"]})
    if not share:
        raise HTTPException(status_code=404, detail="No such share.")
    status = {"accept": "accepted", "reject": "rejected", "together": "together"}[body.action]

    if body.action == "together":
        # A copy of the trip becomes the recipient's own; both keep theirs from here on.
        src = await db.trips.find_one({"_id": share["tripKey"], "deletedAt": None})
        if not src:
            raise HTTPException(status_code=404, detail="That trip no longer exists.")
        now = _now()
        copy = {k: v for k, v in src.items() if k not in ("_id", "userId", "createdAt", "updatedAt", "deletedAt")}
        await db.trips.find_one_and_update(
            {"_id": f"{user['_id']}:{share['tripId']}"},
            {"$set": {**copy, "userId": user["_id"], "updatedAt": now, "deletedAt": None},
             "$setOnInsert": {"createdAt": now}},
            upsert=True,
        )

    doc = await db.shares.find_one_and_update(
        {"_id": share["_id"]}, {"$set": {"status": status, "respondedAt": _now()}}, return_document=True
    )
    owner = await db.users.find_one({"_id": doc["ownerId"]})
    return _share_out(doc, owner)


@router.delete("/shares/{share_id}", status_code=204)
async def unshare(share_id: str, request: Request, user: dict = Depends(current_user)):
    """The owner withdraws a share."""
    await request.app.state.db.shares.delete_one({"_id": ObjectId(share_id), "ownerId": user["_id"]})


# ---- links ------------------------------------------------------------------------------


class LinkedTrip(BaseModel):
    trip: Trip
    owner: Person
    ownerName: str  # full name, for "Shared by ..."


async def _by_token(db, token: str) -> tuple[dict, dict, dict]:
    share = await db.shares.find_one({"token": token, "kind": "link"})
    trip = share and await db.trips.find_one({"_id": share["tripKey"], "deletedAt": None})
    owner = trip and await db.users.find_one({"_id": share["ownerId"]})
    if not (share and trip and owner):
        raise HTTPException(status_code=404, detail="That link has expired.")
    return share, trip, owner


@router.get("/shares/link/{token}", response_model=LinkedTrip)
async def link_trip(token: str, request: Request):
    _, trip, owner = await _by_token(request.app.state.db, token)
    return LinkedTrip(trip=trip_out(trip), owner=_person(owner), ownerName=owner.get("name") or _given_name(owner))


@router.post("/shares/link/{token}/copy", response_model=Trip)
async def copy_linked(token: str, request: Request, user: dict = Depends(current_user)):
    """Whoever opens a link may take the trip into their own list."""
    db = request.app.state.db
    _, src, _ = await _by_token(db, token)
    now = _now()
    copy = {k: v for k, v in src.items() if k not in ("_id", "userId", "createdAt", "updatedAt", "deletedAt")}
    doc = await db.trips.find_one_and_update(
        {"_id": f"{user['_id']}:{src['id']}"},
        {"$set": {**copy, "userId": user["_id"], "updatedAt": now, "deletedAt": None},
         "$setOnInsert": {"createdAt": now}},
        upsert=True, return_document=True,
    )
    return trip_out(doc)


@router.get("/s/{token}", response_class=HTMLResponse)
async def link_page(token: str, request: Request):
    """What a browser sees; the app itself opens airadar://s/{token}."""
    _, trip, owner = await _by_token(request.app.state.db, token)
    t = trip_out(trip)
    return f"""<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{t.flightNumber} · Airadar</title>
<body style="font-family:system-ui;margin:0;padding:32px;background:#0f1115;color:#eee">
<p style="color:#9aa">{owner.get("name") or _given_name(owner)} shared a flight</p>
<h1 style="margin:0">{t.flightNumber} <span style="color:#9aa;font-weight:400">{t.airlineName}</span></h1>
<h2 style="margin:16px 0">{t.departure} → {t.arrival}</h2>
<p>{t.departureTime.strftime('%Y-%m-%d %H:%M')} → {t.arrivalTime.strftime('%H:%M')}</p>
<p style="margin-top:32px"><a href="airadar://s/{token}" style="background:#4f8cff;color:#fff;padding:14px 22px;border-radius:12px;text-decoration:none">Open in Airadar</a></p>
</body>"""


@router.get("/.well-known/assetlinks.json")
async def assetlinks():
    """
    Lets Android open https://<PUBLIC_URL>/s/... straight in the app (App Links).
    ANDROID_SHA256_CERTS: comma-separated SHA-256 fingerprints of the signing keys.
    """
    certs = [c.strip() for c in os.environ.get("ANDROID_SHA256_CERTS", "").split(",") if c.strip()]
    return [{
        "relation": ["delegate_permission/common.handle_all_urls"],
        "target": {
            "namespace": "android_app",
            "package_name": "com.airadar.app",
            "sha256_cert_fingerprints": certs,
        },
    }]
