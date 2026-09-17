"""
Crowd review for a fed flight the automated scorer (feed.py) couldn't settle
either way — see trips.py, which creates a `feed_reviews` document the
moment `feed.score()` returns "pending".

Any signed-in traveller but the one who fed it may cast one Approve/Reject
vote on an open review. A review starts needing 10 votes; every time the
vote count reaches its current target without APPROVE_RATE (70%) being met,
the target grows by 10 more and the review is boosted to the front of the
queue — repeating until 70% is reached or its 7-day deadline passes. Voting
alone only ever produces two automatic outcomes: "confirmed" (≥70%
reached) or "expired" (the deadline passed without that, whatever the vote
count — even zero). "rejected" only ever comes from the admin console
below: nothing here decides a flight is fake on its own, only that the
community couldn't confirm it in time.

The admin routes (gated by ADMIN_EMAIL, checked against the same Google
sign-in every other endpoint already uses) back confirmfeedpage.py's web
console: they can confirm or reject anything outright, and can re-release
an expired review back to the community — which drops the vote-count gate
entirely (existing votes are kept, not discarded) so it only needs 70%
approval among however many votes accumulate, whenever that happens, with
a fresh 7-day deadline.

A confirmed review — whether the community reached it or an admin set it —
teaches feed.py's own community schedule the same way an automatically
approved one does, and pushes "approved"/"rejected" onto the matching trip
via trips.apply_feed_status.
"""

import os
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from pymongo.errors import DuplicateKeyError

from . import feed, trips
from .auth import current_user

router = APIRouter(prefix="/community", tags=["community"])

APPROVE_RATE = 0.7


def _now() -> datetime:
    return datetime.now(timezone.utc)


class ReviewOut(BaseModel):
    id: str
    flightNumber: str
    airlineName: str
    departure: str
    arrival: str
    departureTime: datetime
    arrivalTime: datetime
    status: str
    approveCount: int
    rejectCount: int
    boosted: bool
    myVote: bool | None = None


def _review_out(doc: dict, approve: int, reject: int, my_vote: bool | None = None) -> ReviewOut:
    return ReviewOut(
        id=doc["_id"], flightNumber=doc["flightNumber"], airlineName=doc["airlineName"],
        departure=doc["departure"], arrival=doc["arrival"],
        departureTime=doc["departureTime"], arrivalTime=doc["arrivalTime"],
        status=doc["status"], approveCount=approve, rejectCount=reject,
        boosted=doc.get("boosted", False), myVote=my_vote,
    )


async def _tally(db, review_id: str) -> tuple[int, int]:
    approve = await db.feed_votes.count_documents({"reviewId": review_id, "approve": True})
    reject = await db.feed_votes.count_documents({"reviewId": review_id, "approve": False})
    return approve, reject


async def _expire_overdue(db) -> None:
    """Lazy sweep, same convention trips.py's own _refresh_live uses for
    AirLabs — no separate scheduler process, just checked whenever anyone
    reads the queue or history."""
    await db.feed_reviews.update_many(
        {"status": "pending", "deadline": {"$lt": _now()}},
        {"$set": {"status": "expired", "resolvedAt": _now()}},
    )


async def _resolve_or_escalate(db, review: dict, review_id: str) -> dict:
    """After a vote (or a re-release makes one newly relevant): confirms,
    escalates, or leaves the review exactly as it was. Returns the review
    doc as it now stands."""
    approve, reject = await _tally(db, review_id)
    total = approve + reject
    rate = approve / total if total else 0.0
    no_threshold = review.get("noThreshold", False)
    met_target = no_threshold or total >= review["targetVotes"]

    if met_target and rate >= APPROVE_RATE:
        review = await db.feed_reviews.find_one_and_update(
            {"_id": review_id}, {"$set": {"status": "confirmed", "resolvedAt": _now()}}, return_document=True,
        )
        await trips.apply_feed_status(db, review_id, "approved")
        await feed.remember_schedule(db, review["flightNumber"], review["airlineName"], review["departure"],
                                      review["arrival"], review["departureTime"], review["arrivalTime"])
        return review
    if not no_threshold and total >= review["targetVotes"]:
        # Hit the target without reaching 70% — widen the pool and bump
        # this to the front of the queue instead of just leaving it stuck.
        return await db.feed_reviews.find_one_and_update(
            {"_id": review_id},
            {"$set": {"targetVotes": review["targetVotes"] + 10, "boosted": True}},
            return_document=True,
        )
    return review


@router.get("/queue", response_model=list[ReviewOut])
async def queue(request: Request, user: dict = Depends(current_user)):
    """Open reviews, oldest first — except anything just escalated, which
    jumps to the front — never my own submissions, never one I already
    voted on."""
    db = request.app.state.db
    await _expire_overdue(db)
    voted_ids = {v["reviewId"] async for v in db.feed_votes.find({"userId": user["_id"]}, {"reviewId": 1})}
    docs = [d async for d in db.feed_reviews.find({"status": "pending", "ownerId": {"$ne": user["_id"]}})
            if d["_id"] not in voted_ids]
    docs.sort(key=lambda d: (not d.get("boosted", False), d["createdAt"]))
    out = []
    for d in docs:
        approve, reject = await _tally(db, d["_id"])
        out.append(_review_out(d, approve, reject))
    return out


class VoteRequest(BaseModel):
    approve: bool


@router.post("/{review_id}/vote", response_model=ReviewOut)
async def vote(review_id: str, body: VoteRequest, request: Request, user: dict = Depends(current_user)):
    db = request.app.state.db
    await _expire_overdue(db)
    review = await db.feed_reviews.find_one({"_id": review_id})
    if not review:
        raise HTTPException(status_code=404, detail="No such review.")
    if review["ownerId"] == user["_id"]:
        raise HTTPException(status_code=403, detail="You can't vote on your own submission.")
    if review["status"] != "pending":
        raise HTTPException(status_code=409, detail="This review is no longer open.")
    try:
        await db.feed_votes.insert_one({"reviewId": review_id, "userId": user["_id"], "approve": body.approve, "votedAt": _now()})
    except DuplicateKeyError:
        raise HTTPException(status_code=409, detail="You already voted on this one.")
    review = await _resolve_or_escalate(db, review, review_id)
    approve, reject = await _tally(db, review_id)
    return _review_out(review, approve, reject, my_vote=body.approve)


@router.get("/history/reviews", response_model=list[ReviewOut])
async def history_reviews(request: Request, user: dict = Depends(current_user)):
    """Every review I've cast a vote on, most recently voted first."""
    db = request.app.state.db
    await _expire_overdue(db)
    votes = sorted([v async for v in db.feed_votes.find({"userId": user["_id"]})],
                   key=lambda v: v["votedAt"], reverse=True)
    out = []
    for v in votes:
        review = await db.feed_reviews.find_one({"_id": v["reviewId"]})
        if not review:
            continue
        approve, reject = await _tally(db, review["_id"])
        out.append(_review_out(review, approve, reject, my_vote=v["approve"]))
    return out


@router.get("/history/submissions", response_model=list[ReviewOut])
async def history_submissions(request: Request, user: dict = Depends(current_user)):
    """Every flight I've fed that went to community review, newest first."""
    db = request.app.state.db
    await _expire_overdue(db)
    docs = sorted([d async for d in db.feed_reviews.find({"ownerId": user["_id"]})],
                  key=lambda d: d["createdAt"], reverse=True)
    out = []
    for d in docs:
        approve, reject = await _tally(db, d["_id"])
        out.append(_review_out(d, approve, reject))
    return out


# ---- admin (confirmfeedpage.py's console) --------------------------------------------


def require_admin(user: dict = Depends(current_user)) -> dict:
    admin_email = os.environ.get("ADMIN_EMAIL", "").strip().lower()
    if not admin_email or user["email"].lower() != admin_email:
        raise HTTPException(status_code=403, detail="Not authorized.")
    return user


@router.get("/admin/queue", response_model=list[ReviewOut])
async def admin_queue(column: str, request: Request, admin: dict = Depends(require_admin)):
    if column not in ("pending", "confirmed", "rejected", "expired"):
        raise HTTPException(status_code=400, detail="column must be pending, confirmed, rejected or expired.")
    db = request.app.state.db
    await _expire_overdue(db)
    docs = sorted([d async for d in db.feed_reviews.find({"status": column})],
                  key=lambda d: d["createdAt"], reverse=(column != "pending"))
    out = []
    for d in docs:
        approve, reject = await _tally(db, d["_id"])
        out.append(_review_out(d, approve, reject))
    return out


@router.post("/admin/{review_id}/confirm", response_model=ReviewOut)
async def admin_confirm(review_id: str, request: Request, admin: dict = Depends(require_admin)):
    db = request.app.state.db
    review = await db.feed_reviews.find_one_and_update(
        {"_id": review_id}, {"$set": {"status": "confirmed", "resolvedAt": _now(), "adminOverride": True}},
        return_document=True,
    )
    if not review:
        raise HTTPException(status_code=404, detail="No such review.")
    await trips.apply_feed_status(db, review_id, "approved")
    await feed.remember_schedule(db, review["flightNumber"], review["airlineName"], review["departure"],
                                  review["arrival"], review["departureTime"], review["arrivalTime"])
    approve, reject = await _tally(db, review_id)
    return _review_out(review, approve, reject)


@router.post("/admin/{review_id}/reject", response_model=ReviewOut)
async def admin_reject(review_id: str, request: Request, admin: dict = Depends(require_admin)):
    db = request.app.state.db
    review = await db.feed_reviews.find_one_and_update(
        {"_id": review_id}, {"$set": {"status": "rejected", "resolvedAt": _now(), "adminOverride": True}},
        return_document=True,
    )
    if not review:
        raise HTTPException(status_code=404, detail="No such review.")
    await trips.apply_feed_status(db, review_id, "rejected")
    approve, reject = await _tally(db, review_id)
    return _review_out(review, approve, reject)


@router.post("/admin/{review_id}/release", response_model=ReviewOut)
async def admin_release(review_id: str, request: Request, admin: dict = Depends(require_admin)):
    """Only an expired review can be sent back — no vote-count gate on this
    round, existing votes are kept, and it gets a fresh 7-day deadline."""
    db = request.app.state.db
    review = await db.feed_reviews.find_one({"_id": review_id})
    if not review:
        raise HTTPException(status_code=404, detail="No such review.")
    if review["status"] != "expired":
        raise HTTPException(status_code=400, detail="Only an expired review can be re-released.")
    review = await db.feed_reviews.find_one_and_update(
        {"_id": review_id},
        {"$set": {"status": "pending", "deadline": _now() + trips.REVIEW_WINDOW,
                  "noThreshold": True, "boosted": True, "resolvedAt": None}},
        return_document=True,
    )
    approve, reject = await _tally(db, review_id)
    return _review_out(review, approve, reject)
