"""
Membership tiers and Google Play subscriptions.

  guest     not signed in (the app enforces this one; the server never sees a guest)
  superior  $1/month — cloud sync, friends and sharing, 5 past trips, a month ahead
  premium   $5/month — everything, unlimited, plus historical lookups (FR24)

A new account starts on a Superior trial (TRIAL_DAYS) so sign-up is not a paywall;
when neither trial nor subscription is live the account keeps its data but is
held to guest limits until it subscribes.
"""

import json
import os
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from .auth import current_user

router = APIRouter(prefix="/billing", tags=["billing"])

TRIAL_DAYS = 30
PACKAGE = "com.airadar.app"
PRODUCTS = {"superior_monthly": "superior", "premium_monthly": "premium"}


class Limits(BaseModel):
    maxPastTrips: int | None  # None = unlimited
    futureDays: int | None
    maxTrips: int | None
    historyLookup: bool  # FR24-backed past flights
    sharing: bool


LIMITS = {
    "guest": Limits(maxPastTrips=1, futureDays=7, maxTrips=3, historyLookup=False, sharing=False),
    "superior": Limits(maxPastTrips=5, futureDays=30, maxTrips=None, historyLookup=False, sharing=True),
    "premium": Limits(maxPastTrips=None, futureDays=None, maxTrips=None, historyLookup=True, sharing=True),
}


class Membership(BaseModel):
    tier: str  # guest | superior | premium
    until: datetime | None  # when the current tier lapses (trial or subscription end)
    trial: bool
    limits: Limits


def _now() -> datetime:
    return datetime.now(timezone.utc)


def membership(user: dict) -> Membership:
    """The tier in force right now, from the subscription record or the trial."""
    now = _now()
    sub = user.get("subscription") or {}
    premium_until = sub.get("premiumUntil")
    superior_until = sub.get("superiorUntil")
    trial_until = user.get("trialUntil") or (user.get("createdAt") + timedelta(days=TRIAL_DAYS) if user.get("createdAt") else None)
    if premium_until and premium_until > now:
        return Membership(tier="premium", until=premium_until, trial=False, limits=LIMITS["premium"])
    if superior_until and superior_until > now:
        return Membership(tier="superior", until=superior_until, trial=False, limits=LIMITS["superior"])
    if trial_until and trial_until > now:
        return Membership(tier="superior", until=trial_until, trial=True, limits=LIMITS["superior"])
    return Membership(tier="guest", until=None, trial=False, limits=LIMITS["guest"])


# ---- Google Play ------------------------------------------------------------------


class PlayPurchase(BaseModel):
    productId: str
    purchaseToken: str


async def _play_expiry(product_id: str, token: str) -> datetime:
    """
    Asks Google Play when this subscription expires. Needs a service account with
    access to the Play Console (PLAY_SERVICE_ACCOUNT_JSON = path to its key file).
    Without one the purchase is taken at its word for a month — development only.
    """
    key_path = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", "").strip()
    if not key_path:
        return _now() + timedelta(days=30)

    from google.auth.transport.requests import Request as GRequest
    from google.oauth2 import service_account

    creds = service_account.Credentials.from_service_account_file(
        key_path, scopes=["https://www.googleapis.com/auth/androidpublisher"]
    )
    creds.refresh(GRequest())
    url = (f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PACKAGE}"
           f"/purchases/subscriptionsv2/tokens/{token}")
    async with httpx.AsyncClient() as client:
        r = await client.get(url, headers={"Authorization": f"Bearer {creds.token}"}, timeout=30)
    if r.status_code != 200:
        raise HTTPException(status_code=402, detail=f"Google Play did not confirm the purchase (HTTP {r.status_code}).")
    body = r.json()
    if body.get("subscriptionState") not in ("SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"):
        raise HTTPException(status_code=402, detail=f"Subscription is {body.get('subscriptionState')}.")
    items = body.get("lineItems") or []
    line = next((i for i in items if i.get("productId") == product_id), items[0] if items else None)
    if not line or not line.get("expiryTime"):
        raise HTTPException(status_code=402, detail="Google Play returned no expiry for this purchase.")
    return datetime.fromisoformat(line["expiryTime"].replace("Z", "+00:00"))


@router.post("/google", response_model=Membership)
async def google_purchase(body: PlayPurchase, request: Request, user: dict = Depends(current_user)):
    tier = PRODUCTS.get(body.productId)
    if not tier:
        raise HTTPException(status_code=400, detail="Unknown product.")
    until = await _play_expiry(body.productId, body.purchaseToken)
    field = "premiumUntil" if tier == "premium" else "superiorUntil"
    user = await request.app.state.db.users.find_one_and_update(
        {"_id": user["_id"]},
        {"$set": {
            f"subscription.{field}": until,
            "subscription.productId": body.productId,
            "subscription.purchaseToken": body.purchaseToken,
            "subscription.verified": bool(os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", "").strip()),
            "subscription.updatedAt": _now(),
        }},
        return_document=True,
    )
    return membership(user)


@router.get("/me", response_model=Membership)
async def my_membership(user: dict = Depends(current_user)):
    return membership(user)
