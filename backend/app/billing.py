"""
Membership tiers, paid through Stripe on a web page, redeemed in the app with a token.

  guest     not signed in, or a signed-in account with no live plan
  superior  $1/month
  premium   $5/month

Paying on /pay (Stripe Checkout) mints a token tied to the Stripe subscription.
The first account to redeem the token owns it: the token is bound to that
account's email and works on any number of that person's devices, and is
refused to any other email. The token stays valid as long as Stripe says the
subscription is paid; an order number finds the token again.

A new account starts on a Superior trial (TRIAL_DAYS).
"""

import os
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel

from .auth import current_user

router = APIRouter(tags=["billing"])

TRIAL_DAYS = 30
PLANS = {"superior": "Superior", "premium": "Premium"}
PRICES = {"superior": "US$1 / month", "premium": "US$5 / month"}


class Limits(BaseModel):
    maxPastTrips: int | None  # None = unlimited
    maxUpcomingTrips: int | None  # trips in the air or ahead
    maxTrips: int | None  # everything together
    futureDays: int | None
    historyLookup: bool  # FR24-backed past flights
    sharing: bool


LIMITS = {
    "guest": Limits(maxPastTrips=1, maxUpcomingTrips=None, maxTrips=3, futureDays=7, historyLookup=False, sharing=False),
    "superior": Limits(maxPastTrips=5, maxUpcomingTrips=10, maxTrips=None, futureDays=30, historyLookup=True, sharing=True),
    "premium": Limits(maxPastTrips=None, maxUpcomingTrips=None, maxTrips=None, futureDays=None, historyLookup=True, sharing=True),
}


class Membership(BaseModel):
    tier: str  # guest | superior | premium
    until: datetime | None
    trial: bool
    token: str | None = None  # the redeemed token, so the app can show it
    limits: Limits


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _token_live(tok: dict | None) -> bool:
    return bool(tok) and tok.get("status") == "active" and (tok.get("currentPeriodEnd") or _now()) > _now()


async def membership(db, user: dict) -> Membership:
    """The tier in force right now: a redeemed, paid token first, else the trial, else guest."""
    now = _now()
    tok = await db.tokens.find_one({"_id": user["tokenId"]}) if user.get("tokenId") else None
    if tok and _token_live(tok) and tok.get("boundEmail") == user["email"]:
        plan = tok["plan"]
        return Membership(tier=plan, until=tok["currentPeriodEnd"], trial=False, token=tok["_id"], limits=LIMITS[plan])
    trial_until = user.get("trialUntil") or (
        user["createdAt"] + timedelta(days=TRIAL_DAYS) if user.get("createdAt") else None
    )
    if trial_until and trial_until > now:
        return Membership(tier="superior", until=trial_until, trial=True, limits=LIMITS["superior"])
    return Membership(tier="guest", until=None, trial=False, limits=LIMITS["guest"])


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


def _new_token() -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I
    raw = "".join(secrets.choice(alphabet) for _ in range(12))
    return f"AIR-{raw[:4]}-{raw[4:8]}-{raw[8:]}"


def _new_order() -> str:
    return "ORD-" + "".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(8))


async def _token_for_session(db, session) -> dict:
    """The token for a paid Checkout session — created once, found again after."""
    existing = await db.tokens.find_one({"sessionId": session["id"]})
    if existing:
        return existing
    sub_id = session.get("subscription")
    plan = (session.get("metadata") or {}).get("plan", "superior")
    period_end = None
    status = "active"
    if sub_id:
        sub = _stripe().Subscription.retrieve(sub_id)
        period_end = datetime.fromtimestamp(sub["current_period_end"], tz=timezone.utc)
        status = "active" if sub["status"] in ("active", "trialing", "past_due") else "inactive"
    doc = {
        "_id": _new_token(),
        "order": _new_order(),
        "plan": plan,
        "sessionId": session["id"],
        "subscriptionId": sub_id,
        "customerId": session.get("customer"),
        "buyerEmail": ((session.get("customer_details") or {}).get("email") or session.get("customer_email") or "").lower(),
        "boundEmail": None,
        "status": status,
        "currentPeriodEnd": period_end or (_now() + timedelta(days=31)),
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
            else stripe.Event.construct_from(__import__("json").loads(payload), stripe.api_key)
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
            if kind.startswith("customer.subscription"):
                sub = obj
            else:
                sub = stripe.Subscription.retrieve(sub_id)
            status = "active" if sub["status"] in ("active", "trialing", "past_due") else "inactive"
            await db.tokens.update_one(
                {"subscriptionId": sub_id},
                {"$set": {"status": status,
                          "currentPeriodEnd": datetime.fromtimestamp(sub["current_period_end"], tz=timezone.utc)}},
            )
    return {"ok": True}


# ---- The web page ------------------------------------------------------------------

_STYLE = """<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui;margin:0;padding:32px;background:#0f1115;color:#eee;max-width:560px}
h1{margin:0 0 6px}p.sub{color:#9aa;margin-top:0}.plan{border:1px solid #2a2f3a;border-radius:16px;padding:18px;margin:14px 0}
.plan h2{margin:0 0 4px}.plan .price{color:#9aa;margin-bottom:12px}ul{margin:0 0 14px 18px;color:#cfd3da}
button,a.btn{display:inline-block;background:#4f8cff;color:#fff;border:0;padding:12px 20px;border-radius:12px;font-size:16px;text-decoration:none;cursor:pointer}
code.tok{display:block;font-size:22px;letter-spacing:2px;background:#1a1e26;padding:14px;border-radius:12px;margin:12px 0;word-break:break-all}
input{font-size:16px;padding:10px;border-radius:10px;border:1px solid #2a2f3a;background:#1a1e26;color:#eee;width:100%;box-sizing:border-box;margin:8px 0}
small{color:#9aa}</style>"""


@router.get("/pay", response_class=HTMLResponse)
async def pay_page():
    return f"""<!doctype html><title>Airadar plans</title>{_STYLE}<body>
<h1>Airadar</h1><p class="sub">Pick a plan. You get a token to paste into the app.</p>
<div class="plan"><h2>Superior</h2><div class="price">{PRICES['superior']}</div>
<ul><li>Cloud sync, friends & sharing, recycle bin</li><li>5 past trips · 10 trips ahead · add up to 30 days out</li><li>Past flight lookup</li></ul>
<form method="post" action="/pay/checkout"><input type="hidden" name="plan" value="superior"><button>Subscribe</button></form></div>
<div class="plan"><h2>Premium</h2><div class="price">{PRICES['premium']}</div>
<ul><li>Everything in Superior, no limits</li><li>Flown tracks · Gmail & calendar import</li></ul>
<form method="post" action="/pay/checkout"><input type="hidden" name="plan" value="premium"><button>Subscribe</button></form></div>
<p><a href="/pay/lookup" style="color:#9aa">Already paid? Find your token by order number.</a></p>
</body>"""


@router.post("/pay/checkout")
async def pay_checkout(request: Request, plan: str = Form(...)):
    if plan not in PLANS:
        raise HTTPException(status_code=400, detail="Unknown plan.")
    stripe = _stripe()
    base = _public_url(request)
    session = stripe.checkout.Session.create(
        mode="subscription",
        line_items=[{"price": _price_id(plan), "quantity": 1}],
        success_url=f"{base}/pay/success?session_id={{CHECKOUT_SESSION_ID}}",
        cancel_url=f"{base}/pay",
        metadata={"plan": plan},
    )
    return RedirectResponse(session["url"], status_code=303)


@router.get("/pay/success", response_class=HTMLResponse)
async def pay_success(session_id: str, request: Request):
    stripe = _stripe()
    session = stripe.checkout.Session.retrieve(session_id)
    if session.get("payment_status") not in ("paid", "no_payment_required"):
        return HTMLResponse(f"<!doctype html>{_STYLE}<body><h1>Not paid yet</h1><p class='sub'>Stripe has not confirmed this payment.</p></body>")
    tok = await _token_for_session(request.app.state.db, session)
    return f"""<!doctype html><title>Your Airadar token</title>{_STYLE}<body>
<h1>Thank you</h1><p class="sub">{PLANS[tok['plan']]} · order <b>{tok['order']}</b></p>
<p>Your token — paste it in the app under Settings › Plan:</p>
<code class="tok" id="t">{tok['_id']}</code>
<button onclick="navigator.clipboard.writeText(document.getElementById('t').textContent).then(()=>this.textContent='Copied')">Copy token</button>
<p><small>Keep the order number: it finds this token again at /pay/lookup. The token works on every device signed in with the first Google account that redeems it, and on no other account.</small></p>
</body>"""


@router.get("/pay/lookup", response_class=HTMLResponse)
async def pay_lookup(request: Request, order: str | None = None):
    found = None
    if order:
        found = await request.app.state.db.tokens.find_one({"order": order.strip().upper()})
    result = ""
    if order and not found:
        result = "<p style='color:#ff8a80'>No order with that number.</p>"
    elif found:
        result = f"<p>{PLANS[found['plan']]} · {'active' if _token_live(found) else 'not active'}</p><code class='tok'>{found['_id']}</code>"
    return f"""<!doctype html><title>Find your token</title>{_STYLE}<body>
<h1>Find your token</h1><p class="sub">Enter the order number from your receipt.</p>
<form method="get"><input name="order" placeholder="ORD-XXXXXXXX" value="{order or ''}"><button>Find</button></form>{result}
<p><a href="/pay" style="color:#9aa">Back to plans</a></p></body>"""


# ---- Redeeming in the app -----------------------------------------------------------


class Redeem(BaseModel):
    token: str


@router.post("/billing/redeem", response_model=Membership)
async def redeem(body: Redeem, request: Request, user: dict = Depends(current_user)):
    db = request.app.state.db
    code = body.token.strip().upper()
    tok = await db.tokens.find_one({"_id": code})
    if not tok:
        raise HTTPException(status_code=404, detail="No such token.")
    if not _token_live(tok):
        raise HTTPException(status_code=402, detail="This token's subscription is not active.")
    if tok.get("boundEmail") and tok["boundEmail"] != user["email"]:
        raise HTTPException(status_code=403, detail="This token belongs to another account.")
    if not tok.get("boundEmail"):
        # First redemption: the token is this person's from now on.
        await db.tokens.update_one({"_id": code}, {"$set": {"boundEmail": user["email"], "boundAt": _now()}})
    user = await db.users.find_one_and_update({"_id": user["_id"]}, {"$set": {"tokenId": code}}, return_document=True)
    return await membership(db, user)


@router.get("/billing/me", response_model=Membership)
async def my_membership(request: Request, user: dict = Depends(current_user)):
    return await membership(request.app.state.db, user)
