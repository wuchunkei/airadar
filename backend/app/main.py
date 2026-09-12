"""
Airadar backend. Resolves a flight number + date to one Flight record for the app.

AirLabs is the only status source; this layer keeps its key off the phone and
gives the app one stable shape to parse. Signed-in travellers (Google) also keep
their trips here — see auth.py and trips.py.
"""

import os
from datetime import date

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Request

from . import airlabs, auth, billing, db, fr24, social, trips
from .billing import membership
from .schema import Airport, Flight

app = FastAPI(title="Airadar backend", version="0.2.0")
app.include_router(auth.router)
app.include_router(trips.router)
app.include_router(social.router)
app.include_router(billing.router)


def _http() -> httpx.AsyncClient:
    return app.state.http


@app.on_event("startup")
async def _startup():
    app.state.http = httpx.AsyncClient()
    app.state.db = db.connect()
    await db.ensure_indexes(app.state.db)


@app.on_event("shutdown")
async def _shutdown():
    await app.state.http.aclose()
    db.close()


def require_token(x_airadar_token: str | None = Header(default=None)):
    """A shared secret between your build of the app and this server."""
    expected = os.environ.get("APP_TOKEN", "").strip()
    if expected and x_airadar_token != expected:
        raise HTTPException(status_code=401, detail="bad or missing X-Airadar-Token")


@app.get("/health")
async def health():
    return {
        "ok": True,
        "airlabs": bool(os.environ.get("AIRLABS_API_KEY")),
        "google": bool(os.environ.get("GOOGLE_CLIENT_ID")),
        "jwt": bool(os.environ.get("JWT_SECRET")),
        "history": fr24.enabled(),
        "stripe": bool(os.environ.get("STRIPE_SECRET_KEY")),
    }


async def optional_user(request: Request, authorization: str | None = Header(default=None)) -> dict | None:
    """The signed-in traveller if a bearer token came along; None otherwise."""
    if not authorization:
        return None
    try:
        return await auth.current_user(request, authorization)
    except HTTPException:
        return None


@app.get("/flights/{number}/{day}", response_model=Flight, dependencies=[Depends(require_token)])
async def flight(number: str, day: date, user: dict | None = Depends(optional_user)):
    errors: list[str] = []
    try:
        return await _airlabs_flight(number, day)
    except airlabs.AirLabsError as e:
        if e.quota_exhausted:
            raise HTTPException(status_code=429, detail={"flight": number.upper(), "date": day.isoformat(), "error": str(e)})
        errors.append(str(e))

    # Past flights AirLabs no longer carries: the history service, for Premium only.
    if user is not None and (await membership(app.state.db, user)).limits.historyLookup and fr24.enabled():
        try:
            return await fr24.flight(_http(), app.state.db, number, day)
        except fr24.HistoryError as e:
            errors.append(str(e))
    elif user is not None and fr24.enabled() and day < date.today():
        errors.append("Past flights beyond the airline's timetable need Premium.")

    raise HTTPException(status_code=502, detail={"flight": number.upper(), "date": day.isoformat(), "error": " ".join(errors)})


async def _airlabs_flight(number: str, day: date) -> Flight:
    # Live status if AirLabs has this very day's flight; the timetable otherwise.
    # A live record for a different day is never passed off as the asked-for one.
    if abs((day - date.today()).days) <= 1:
        try:
            live = await airlabs.flight(_http(), number, day)
            if live.departureTime.date() == day:
                return live
        except airlabs.AirLabsError as e:
            if e.quota_exhausted:
                raise
    return await airlabs.schedule(_http(), number, day)


@app.get("/airports/{iata}", response_model=Airport, dependencies=[Depends(require_token)])
async def airport(iata: str):
    try:
        return await airlabs.airport(_http(), iata)
    except airlabs.AirLabsError as e:
        raise HTTPException(status_code=502, detail=str(e))
