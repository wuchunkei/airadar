"""
Airadar backend. Resolves a flight number + date to one Flight record for the app.

AirLabs is the only status source; this layer keeps its key off the phone and
gives the app one stable shape to parse.
"""

import os
from datetime import date

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException

from . import airlabs
from .schema import Airport, Flight

app = FastAPI(title="Airadar backend", version="0.1.0")


def _http() -> httpx.AsyncClient:
    return app.state.http


@app.on_event("startup")
async def _startup():
    app.state.http = httpx.AsyncClient()


@app.on_event("shutdown")
async def _shutdown():
    await app.state.http.aclose()


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
    }


@app.get("/flights/{number}/{day}", response_model=Flight, dependencies=[Depends(require_token)])
async def flight(number: str, day: date):
    # Live status within a day of now, timetable beyond that.
    near = abs((day - date.today()).days) <= 1
    try:
        return await (airlabs.flight if near else airlabs.schedule)(_http(), number, day)
    except airlabs.AirLabsError as e:
        status = 429 if e.quota_exhausted else 502
        raise HTTPException(status_code=status, detail={"flight": number.upper(), "date": day.isoformat(), "error": str(e)})


@app.get("/airports/{iata}", response_model=Airport, dependencies=[Depends(require_token)])
async def airport(iata: str):
    try:
        return await airlabs.airport(_http(), iata)
    except airlabs.AirLabsError as e:
        raise HTTPException(status_code=502, detail=str(e))
