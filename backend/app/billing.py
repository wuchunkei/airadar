"""
Membership tiers, paid through Stripe on a web page, unlocked in the app with a token.

  guest     no token — the app works with small limits, no sign-in
  superior  US$1/month
  premium   US$5/month

Paying on /pay (Stripe Checkout) mints a token tied to the Stripe subscription.
In the app the token comes first: it is checked and bound to that phone, and
only then may the traveller sign in with Google; the first Google account used
with the token is bound to it too. Another phone, or another account on the
same phone, is refused. The token stays valid while Stripe says the
subscription is paid, plus GRACE_DAYS. An order number finds a token again.

Upgrading keeps the token: the unused part of the Superior month is credited
against the first Premium month, the Superior subscription is cancelled, and
the token simply becomes Premium.
"""

import json
import os
import re
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel

from .auth import current_user

router = APIRouter(tags=["billing"])

GRACE_DAYS = 3  # a paid plan keeps working this long after its period ends
PLANS = {"superior": "Superior", "premium": "Premium"}
PRICE_CENTS = {"superior": 100, "premium": 500}
PRICES = {"superior": "US$1 / month", "premium": "US$5 / month"}


class Limits(BaseModel):
    maxPastTrips: int | None  # None = unlimited
    maxUpcomingTrips: int | None  # trips in the air or ahead
    maxTrips: int | None  # everything together
    futureDays: int | None
    sharing: bool


LIMITS = {
    "guest": Limits(maxPastTrips=1, maxUpcomingTrips=None, maxTrips=3, futureDays=7, sharing=False),
    "superior": Limits(maxPastTrips=5, maxUpcomingTrips=10, maxTrips=None, futureDays=30, sharing=True),
    "premium": Limits(maxPastTrips=None, maxUpcomingTrips=None, maxTrips=None, futureDays=None, sharing=True),
}


class Membership(BaseModel):
    tier: str  # guest | superior | premium
    until: datetime | None  # end of the paid period; grace runs GRACE_DAYS past it
    grace: bool = False  # past the period end, inside the grace days
    token: str | None = None
    limits: Limits


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _token_live(tok: dict | None) -> bool:
    """Paid and inside the period, or within the grace days after it. A cancelled subscription ends at once."""
    if not tok or tok.get("status") != "active":
        return False
    end = tok.get("currentPeriodEnd") or _now()
    return end + timedelta(days=GRACE_DAYS) > _now()


def _membership_of(tok: dict | None) -> Membership:
    if tok and _token_live(tok):
        plan = tok["plan"]
        return Membership(tier=plan, until=tok["currentPeriodEnd"], grace=tok["currentPeriodEnd"] <= _now(),
                          token=tok["_id"], limits=LIMITS[plan])
    return Membership(tier="guest", until=None, limits=LIMITS["guest"])


async def membership(db, user: dict) -> Membership:
    """The tier in force for a signed-in account: its token, if paid and bound to this email."""
    tok = await db.tokens.find_one({"_id": user["tokenId"]}) if user.get("tokenId") else None
    if tok and tok.get("boundEmail") == user["email"]:
        return _membership_of(tok)
    return _membership_of(None)


# ---- Stripe -----------------------------------------------------------------------


def _stripe():
    import stripe
    key = os.environ.get("STRIPE_SECRET_KEY", "").strip()
    if not key:
        raise HTTPException(status_code=500, detail="STRIPE_SECRET_KEY is not set on the server.")
    stripe.api_key = key
    return stripe


def _price_id(plan: str) -> str:
    pid = os.environ.get(f"STRIPE_PRICE_{plan.upper()}", "").strip()
    if not pid:
        raise HTTPException(status_code=500, detail=f"STRIPE_PRICE_{plan.upper()} is not set on the server.")
    return pid


def _public_url(request: Request) -> str:
    return os.environ.get("PUBLIC_URL", "").strip().rstrip("/") or str(request.base_url).rstrip("/")


_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I


def _new_token() -> str:
    """16 hex characters, e.g. 3F9A0C7D21B4E8F6."""
    return secrets.token_hex(8).upper()


def normalize(token: str) -> str:
    return re.sub(r"[^0-9A-Z]", "", token.strip().upper())


async def seed_lifetime_tokens(db) -> None:
    """
    LIFETIME_PREMIUM_TOKENS: comma-separated tokens that are Premium forever —
    for testing and for the developer's own phone. Created if missing, never
    tied to Stripe.
    """
    forever = datetime(2999, 1, 1, tzinfo=timezone.utc)
    for raw in os.environ.get("LIFETIME_PREMIUM_TOKENS", "").split(","):
        code = normalize(raw)
        if len(code) < 8:
            continue
        await db.tokens.update_one(
            {"_id": code},
            {"$setOnInsert": {"order": f"ORD-LIFE-{code[:6]}", "plan": "premium", "status": "active",
                              "currentPeriodEnd": forever, "deviceId": None, "boundEmail": None,
                              "lifetime": True, "createdAt": _now()},
             "$set": {"plan": "premium", "status": "active", "currentPeriodEnd": forever}},
            upsert=True,
        )


def _new_order() -> str:
    return "ORD-" + "".join(secrets.choice(_ALPHABET) for _ in range(8))


def _sub_state(sub) -> tuple[str, datetime]:
    status = "active" if sub["status"] in ("active", "trialing", "past_due") else "inactive"
    return status, datetime.fromtimestamp(sub["current_period_end"], tz=timezone.utc)


async def _token_for_session(db, session) -> dict:
    """The token for a paid Checkout session — created (or, for an upgrade, changed) once."""
    existing = await db.tokens.find_one({"sessionId": session["id"]})
    if existing:
        return existing
    meta = session.get("metadata") or {}
    sub_id = session.get("subscription")
    status, period_end = ("active", _now() + timedelta(days=31))
    if sub_id:
        status, period_end = _sub_state(_stripe().Subscription.retrieve(sub_id))

    upgrade_of = meta.get("upgradeToken")
    if upgrade_of:
        old = await db.tokens.find_one({"_id": upgrade_of})
        if old:
            if old.get("subscriptionId") and old["subscriptionId"] != sub_id:
                try:
                    _stripe().Subscription.cancel(old["subscriptionId"])
                except Exception:
                    pass  # already gone; the new plan stands either way
            await db.tokens.update_one(
                {"_id": upgrade_of},
                {"$set": {"plan": "premium", "sessionId": session["id"], "subscriptionId": sub_id,
                          "status": status, "currentPeriodEnd": period_end, "upgradedAt": _now()}},
            )
            return await db.tokens.find_one({"_id": upgrade_of})

    doc = {
        "_id": _new_token(),
        "order": _new_order(),
        "plan": meta.get("plan", "superior"),
        "sessionId": session["id"],
        "subscriptionId": sub_id,
        "customerId": session.get("customer"),
        "buyerEmail": ((session.get("customer_details") or {}).get("email") or session.get("customer_email") or "").lower(),
        "deviceId": None,
        "boundEmail": None,
        "status": status,
        "currentPeriodEnd": period_end,
        "createdAt": _now(),
    }
    await db.tokens.insert_one(doc)
    return doc


@router.post("/billing/stripe/webhook")
async def stripe_webhook(request: Request):
    """Stripe tells us about payments and renewals; tokens follow the subscription."""
    stripe = _stripe()
    payload = await request.body()
    secret = os.environ.get("STRIPE_WEBHOOK_SECRET", "").strip()
    try:
        event = stripe.Webhook.construct_event(payload, request.headers.get("stripe-signature", ""), secret) if secret \
            else stripe.Event.construct_from(json.loads(payload), stripe.api_key)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Bad webhook: {e}")

    db = request.app.state.db
    kind = event["type"]
    obj = event["data"]["object"]
    if kind == "checkout.session.completed" and obj.get("payment_status") in ("paid", "no_payment_required"):
        await _token_for_session(db, obj)
    elif kind in ("customer.subscription.updated", "customer.subscription.deleted", "invoice.paid", "invoice.payment_failed"):
        sub_id = obj.get("id") if kind.startswith("customer.subscription") else obj.get("subscription")
        if sub_id:
            sub = obj if kind.startswith("customer.subscription") else stripe.Subscription.retrieve(sub_id)
            status, period_end = _sub_state(sub)
            await db.tokens.update_one({"subscriptionId": sub_id}, {"$set": {"status": status, "currentPeriodEnd": period_end}})
    return {"ok": True}


# ---- Checkout, upgrade, lookup --------------------------------------------------------


def _checkout(request: Request, plan: str, metadata: dict, discounts: list | None = None):
    stripe = _stripe()
    base = _public_url(request)
    session = stripe.checkout.Session.create(
        mode="subscription",
        line_items=[{"price": _price_id(plan), "quantity": 1}],
        success_url=f"{base}/pay/success?session_id={{CHECKOUT_SESSION_ID}}",
        cancel_url=f"{base}/pay",
        metadata=metadata,
        **({"discounts": discounts} if discounts else {}),
    )
    return RedirectResponse(session["url"], status_code=303)


@router.post("/pay/checkout")
async def pay_checkout(request: Request, plan: str = Form(...)):
    if plan not in PLANS:
        raise HTTPException(status_code=400, detail="Unknown plan.")
    return _checkout(request, plan, {"plan": plan})


def _upgrade_credit_cents(tok: dict) -> int:
    """The unused share of the current Superior month, in cents, capped at the month's price."""
    end = tok.get("currentPeriodEnd")
    if not end:
        return 0
    remaining = (end - _now()).total_seconds()
    fraction = max(0.0, min(1.0, remaining / (30 * 24 * 3600)))
    return int(round(PRICE_CENTS["superior"] * fraction))


class UpgradeCheck(BaseModel):
    token: str


@router.post("/pay/api/upgrade-check")
async def upgrade_check(body: UpgradeCheck, request: Request):
    """Is this token a live Superior? If so, what will the first Premium month cost?"""
    tok = await request.app.state.db.tokens.find_one({"_id": normalize(body.token)})
    if not tok:
        raise HTTPException(status_code=404, detail="No such token.")
    if tok["plan"] == "premium":
        raise HTTPException(status_code=400, detail="This token is already Premium.")
    if not _token_live(tok):
        raise HTTPException(status_code=402, detail="This token's subscription is not active.")
    credit = _upgrade_credit_cents(tok)
    return {"ok": True, "creditCents": credit, "firstMonthCents": PRICE_CENTS["premium"] - credit,
            "periodEnd": tok["currentPeriodEnd"].isoformat()}


@router.post("/pay/upgrade")
async def pay_upgrade(request: Request, token: str = Form(...)):
    db = request.app.state.db
    code = normalize(token)
    tok = await db.tokens.find_one({"_id": code})
    if not tok or tok["plan"] != "superior" or not _token_live(tok):
        raise HTTPException(status_code=400, detail="Only a live Superior token can be upgraded.")
    credit = _upgrade_credit_cents(tok)
    discounts = None
    if credit > 0:
        coupon = _stripe().Coupon.create(amount_off=credit, currency="usd", duration="once",
                                         name=f"Unused Superior time ({code})")
        discounts = [{"coupon": coupon["id"]}]
    return _checkout(request, "premium", {"plan": "premium", "upgradeToken": code}, discounts)


@router.get("/pay/api/lookup")
async def lookup_api(order: str, request: Request):
    tok = await request.app.state.db.tokens.find_one({"order": order.strip().upper()})
    if not tok:
        raise HTTPException(status_code=404, detail="No order with that number.")
    return {"token": tok["_id"], "plan": tok["plan"], "active": _token_live(tok)}


# ---- The app's side of the token -----------------------------------------------------------


class TokenCheck(BaseModel):
    token: str
    deviceId: str


class TokenStatus(BaseModel):
    plan: str
    until: datetime
    grace: bool
    boundEmail: str | None  # who, if anyone, has already signed in with it


@router.post("/billing/token/check", response_model=TokenStatus)
async def token_check(body: TokenCheck, request: Request):
    """
    The app's first step, before any sign-in: the token is validated and bound to
    this phone if it is not yet bound to one. Another phone is refused.
    """
    db = request.app.state.db
    code = normalize(body.token)
    tok = await db.tokens.find_one({"_id": code})
    if not tok:
        raise HTTPException(status_code=404, detail="No such token.")
    if not _token_live(tok):
        raise HTTPException(status_code=402, detail="This token's subscription is not active.")
    if tok.get("deviceId") and tok["deviceId"] != body.deviceId:
        raise HTTPException(status_code=403, detail="This token is in use on another phone.")
    if not tok.get("deviceId"):
        await db.tokens.update_one({"_id": code}, {"$set": {"deviceId": body.deviceId, "deviceBoundAt": _now()}})
    return TokenStatus(plan=tok["plan"], until=tok["currentPeriodEnd"], grace=tok["currentPeriodEnd"] <= _now(),
                       boundEmail=tok.get("boundEmail"))


@router.post("/billing/redeem", response_model=Membership)
async def redeem(body: TokenCheck, request: Request, user: dict = Depends(current_user)):
    """After Google sign-in: ties the token to this account (first come) and raises the plan."""
    db = request.app.state.db
    code = normalize(body.token)
    tok = await db.tokens.find_one({"_id": code})
    if not tok:
        raise HTTPException(status_code=404, detail="No such token.")
    if not _token_live(tok):
        raise HTTPException(status_code=402, detail="This token's subscription is not active.")
    if tok.get("deviceId") and tok["deviceId"] != body.deviceId:
        raise HTTPException(status_code=403, detail="This token is in use on another phone.")
    if tok.get("boundEmail") and tok["boundEmail"] != user["email"]:
        raise HTTPException(status_code=403, detail="This token was set up with a different Google account.")
    updates = {}
    if not tok.get("deviceId"):
        updates["deviceId"] = body.deviceId
    if not tok.get("boundEmail"):
        updates.update({"boundEmail": user["email"], "boundAt": _now()})
    if updates:
        await db.tokens.update_one({"_id": code}, {"$set": updates})
    user = await db.users.find_one_and_update({"_id": user["_id"]}, {"$set": {"tokenId": code}}, return_document=True)
    return await membership(db, user)


@router.get("/billing/me", response_model=Membership)
async def my_membership(request: Request, user: dict = Depends(current_user)):
    return await membership(request.app.state.db, user)


# ---- Pages ------------------------------------------------------------------------------------

from .paypage import PAGE, SUCCESS, STYLE  # noqa: E402


@router.get("/pay", response_class=HTMLResponse)
async def pay_page():
    return PAGE


@router.get("/pay/success", response_class=HTMLResponse)
async def pay_success(session_id: str, request: Request):
    stripe = _stripe()
    session = stripe.checkout.Session.retrieve(session_id)
    if session.get("payment_status") not in ("paid", "no_payment_required"):
        return HTMLResponse(f"<!doctype html>{STYLE}<body><main><h1>Not paid yet</h1><p class='sub'>Stripe has not confirmed this payment.</p></main></body>")
    tok = await _token_for_session(request.app.state.db, session)
    return SUCCESS.replace("{{PLAN}}", PLANS[tok["plan"]]).replace("{{ORDER}}", tok["order"]).replace("{{TOKEN}}", tok["_id"])
