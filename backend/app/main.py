"""
Airadar backend. Resolves a flight number + date to one Flight record for the app.

AirLabs is the only status source; this layer keeps its key off the phone and
gives the app one stable shape to parse. Signed-in travellers (Google) also keep
their trips here — see auth.py and trips.py.
"""

import os
from datetime import date

import httpx
import airportsdata
import pycountry
from fastapi import Depends, FastAPI, Header, HTTPException

from . import aerodatabox, airlabs, auth, billing, db, social, trips
from .schema import Airport, Flight

_AIRPORTS_TABLE = airportsdata.load("IATA")

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
        "aerodatabox": bool(os.environ.get("AERODATABOX_KEY")),
        "google": bool(os.environ.get("GOOGLE_CLIENT_ID")),
        "jwt": bool(os.environ.get("JWT_SECRET")),
        "stripe": bool(os.environ.get("STRIPE_SECRET_KEY")),
    }


@app.get("/flights/{number}/{day}", response_model=Flight, dependencies=[Depends(require_token)])
async def flight(number: str, day: date):
    try:
        return await _airlabs_flight(number, day)
    except airlabs.AirLabsError as e:
        if e.quota_exhausted:
            raise HTTPException(status_code=429, detail={"flight": number.upper(), "date": day.isoformat(), "error": str(e)})
        # AirLabs has nothing at all — a real, common coverage gap, not always
        # a dead flight number (see airlabs.schedule). AeroDataBox, a second
        # paid-adjacent source, gets one shot at a real schedule before this
        # gives up and reports AirLabs' own (adsbdb-enriched) error instead.
        try:
            return await aerodatabox.flight(_http(), number, day)
        except aerodatabox.AeroDataBoxError:
            raise HTTPException(status_code=502, detail={"flight": number.upper(), "date": day.isoformat(), "error": str(e)})


async def _airlabs_flight(number: str, day: date) -> Flight:
    return await airlabs.lookup(_http(), number, day)


_airports: dict[str, Airport] = {}  # airports do not move; looked up once per process


def _bundled_airport(code: str) -> Airport | None:
    """The airportsdata table (MIT, offline): proper city, country and zone for ~28k airports."""
    row = _AIRPORTS_TABLE.get(code)
    if not row or not row.get("tz"):
        return None
    country = pycountry.countries.get(alpha_2=row["country"])
    return Airport(
        iata=code, icao=row.get("icao") or "", name=row.get("name") or code,
        city=row.get("city") or row.get("name") or code,
        country=(getattr(country, "common_name", None) or country.name) if country else row["country"],
        countryCode=row["country"], latitude=float(row["lat"]), longitude=float(row["lon"]), zoneId=row["tz"],
    )


@app.get("/airports/{iata}", response_model=Airport, dependencies=[Depends(require_token)])
async def airport(iata: str):
    code = iata.upper()
    if code in _airports:
        return _airports[code]
    a = _bundled_airport(code)
    if a is None:
        try:
            a = await airlabs.airport(_http(), code)
        except airlabs.AirLabsError as e:
            raise HTTPException(status_code=502, detail=str(e))
    _airports[code] = a
    return a
