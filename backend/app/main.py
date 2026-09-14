"""
Airadar backend. Resolves a flight number + date to one Flight record for the app.

AirLabs is the only status source; this layer keeps its key off the phone and
gives the app one stable shape to parse. Signed-in travellers (Google) also keep
their trips here — see auth.py and trips.py.
"""

import os
from datetime import date

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException

from . import airlabs, auth, billing, db, social, trips
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
    await billing.seed_lifetime_tokens(app.state.db)


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
        "stripe": bool(os.environ.get("STRIPE_SECRET_KEY")),
    }


@app.get("/flights/{number}/{day}", response_model=Flight, dependencies=[Depends(require_token)])
async def flight(number: str, day: date):
    try:
        return await _airlabs_flight(number, day)
    except airlabs.AirLabsError as e:
        status = 429 if e.quota_exhausted else 502
        raise HTTPException(status_code=status, detail={"flight": number.upper(), "date": day.isoformat(), "error": str(e)})


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


_airports: dict[str, Airport] = {}  # airports do not move; one AirLabs call each per process


@app.get("/airports/{iata}", response_model=Airport, dependencies=[Depends(require_token)])
async def airport(iata: str):
    code = iata.upper()
    if code in _airports:
        return _airports[code]
    try:
        a = await airlabs.airport(_http(), code)
    except airlabs.AirLabsError as e:
        raise HTTPException(status_code=502, detail=str(e))
    _airports[code] = a
    return a
