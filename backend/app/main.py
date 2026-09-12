"""
Airadar backend. Resolves a flight number + date to one Flight record for the app.

Policy, as decided: AirLabs answers first. Only when AirLabs cannot — quota
exhausted, key trouble, or an error — does Umetrip get asked. The response says
which one answered so the app can show it.
"""

import os
from datetime import date, timedelta

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException

from . import airlabs, umetrip
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
        "umetrip": umetrip.enabled(),
    }


@app.get("/flights/{number}/{day}", response_model=Flight, dependencies=[Depends(require_token)])
async def flight(number: str, day: date):
    errors: list[str] = []

    # AirLabs: live status within a day of now, timetable beyond that.
    try:
        near = abs((day - date.today()).days) <= 1
        return await (airlabs.flight if near else airlabs.schedule)(_http(), number, day)
    except airlabs.AirLabsError as e:
        errors.append(f"airlabs: {e}")
        # Anything other than "out of quota" is still worth one Umetrip try —
        # the number may simply be one AirLabs does not carry.

    if umetrip.enabled():
        try:
            result = await umetrip.flight(number, day)
            result.fallback = True
            return result
        except umetrip.UmetripError as e:
            errors.append(f"umetrip: {e}")
        except Exception as e:  # protobuf / ctypes surprises from the 2019 client
            errors.append(f"umetrip: unexpected {type(e).__name__}: {e}")

    raise HTTPException(status_code=502, detail={"flight": number.upper(), "date": day.isoformat(), "errors": errors})


@app.get("/airports/{iata}", response_model=Airport, dependencies=[Depends(require_token)])
async def airport(iata: str):
    try:
        return await airlabs.airport(_http(), iata)
    except airlabs.AirLabsError as e:
        raise HTTPException(status_code=502, detail=str(e))


@app.get("/probe/umetrip", dependencies=[Depends(require_token)])
async def probe_umetrip(number: str = "CA1501", day: date | None = None):
    """
    Exercises the vendored 2019 Umetrip protocol end to end. Run this once after
    deploying; if it fails, the fallback is dead and AirLabs is all you have.
    """
    day = day or date.today() + timedelta(days=1)
    try:
        return await umetrip.flight(number, day)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"{type(e).__name__}: {e}")
