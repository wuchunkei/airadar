"""
Airadar history service — a tiny box that asks Flightradar24 about past flights.

Runs on its own machine (the WARP exit), so the main backend's address never
touches FR24. The main backend calls GET /history/{number}/{date} with the
X-Service-Token header and caches whatever comes back.

Anonymous FR24 returns roughly a week either side of today. Deeper history
needs an FR24 account: set FR24_USER / FR24_PASSWORD and the account's plan
decides the reach (Gold: about a year). This uses FR24's private web
endpoints and can stop working at any time; the caller treats every failure
as "not found".
"""

import os
import threading
import time
from datetime import date, datetime, timezone

from curl_cffi import requests
from fastapi import FastAPI, Header, HTTPException
from FlightRadarAPI import FlightRadar24API
from FlightRadarAPI.core import Core

app = FastAPI(title="Airadar history", version="0.1.0")

LIST_URL = "https://api.flightradar24.com/common/v1/flight/list.json"

_lock = threading.Lock()
_session = requests.Session(impersonate="chrome")
_api = FlightRadar24API()
_token: str | None = None
_token_at = 0.0


def _login_token() -> str | None:
    """A logged-in FR24 session's token, refreshed every 6 hours; None when no account is set."""
    global _token, _token_at
    user, password = os.environ.get("FR24_USER", "").strip(), os.environ.get("FR24_PASSWORD", "").strip()
    if not user or not password:
        return None
    with _lock:
        if _token and time.time() - _token_at < 6 * 3600:
            return _token
        _api.login(user, password)
        # The package keeps the session cookie FR24's web app sends as ?token=
        _token = _api._FlightRadar24API__client.get_cookie("_frPl")  # noqa: SLF001
        _token_at = time.time()
        return _token


def _require(x_service_token: str | None) -> None:
    expected = os.environ.get("SERVICE_TOKEN", "").strip()
    if expected and x_service_token != expected:
        raise HTTPException(status_code=401, detail="bad X-Service-Token")


def _local(ts: int | None, offset: int | None) -> str | None:
    """FR24 gives UTC epochs plus the airport's offset; the app wants local clock time."""
    if not ts:
        return None
    return datetime.fromtimestamp(ts + (offset or 0), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def _status(text: str) -> str:
    t = (text or "").lower()
    if "cancel" in t:
        return "CANCELLED"
    if "divert" in t:
        return "DIVERTED"
    if "landed" in t or "arrived" in t:
        return "LANDED"
    if "estimated" in t or "in air" in t or "departed" in t:
        return "IN_FLIGHT"
    if "delayed" in t:
        return "DELAYED"
    return "SCHEDULED"


def _fetch(number: str, day: date) -> dict | None:
    """Every page of the number's history until the wanted day is passed."""
    token = _login_token()
    page = 1
    while page <= 20:
        params = {"query": number, "fetchBy": "flight", "page": page, "limit": 100}
        if token:
            params["token"] = token
        r = _session.get(LIST_URL, params=params, headers=Core.json_headers, timeout=30)
        if r.status_code != 200:
            raise HTTPException(status_code=502, detail=f"FR24 answered HTTP {r.status_code}")
        resp = r.json().get("result", {}).get("response", {})
        rows = resp.get("data") or []
        oldest = None
        for f in rows:
            sched = f.get("time", {}).get("scheduled", {}) or {}
            dep = sched.get("departure")
            origin = f.get("airport", {}).get("origin") or {}
            if not dep or not origin:
                continue
            offset = (origin.get("timezone") or {}).get("offset")
            flown = datetime.fromtimestamp(dep + (offset or 0), tz=timezone.utc).date()
            oldest = flown if oldest is None or flown < oldest else oldest
            if flown == day:
                return _shape(f, number, day)
        if not rows or not resp.get("page", {}).get("more") or (oldest and oldest < day):
            return None
        page += 1
    return None


def _shape(f: dict, number: str, day: date) -> dict:
    ap = f.get("airport", {})
    origin, dest = ap.get("origin") or {}, ap.get("destination") or {}
    o_off = (origin.get("timezone") or {}).get("offset")
    d_off = (dest.get("timezone") or {}).get("offset")
    t = f.get("time", {})
    sched, real, est = t.get("scheduled") or {}, t.get("real") or {}, t.get("estimated") or {}
    std = _local(sched.get("departure"), o_off)
    sta = _local(sched.get("arrival"), d_off)
    atd = _local(real.get("departure"), o_off)
    delay = 0
    if sched.get("departure") and real.get("departure"):
        delay = max(0, int((real["departure"] - sched["departure"]) / 60))
    aircraft = (f.get("aircraft") or {}).get("model") or {}
    airline = f.get("airline") or {}
    return {
        "id": f"{number}-{day.isoformat()}",
        "flightNumber": number,
        "airlineName": airline.get("name") or number[:2],
        "departure": (origin.get("code") or {}).get("iata", ""),
        "arrival": (dest.get("code") or {}).get("iata", ""),
        "departureTerminal": ((origin.get("info") or {}).get("terminal")),
        "arrivalTerminal": ((dest.get("info") or {}).get("terminal")),
        "departureGate": ((origin.get("info") or {}).get("gate")),
        "arrivalGate": ((dest.get("info") or {}).get("gate")),
        "departureTime": std,
        "arrivalTime": sta,
        "actualDeparture": atd,
        "actualArrival": _local(real.get("arrival") or est.get("arrival"), d_off),
        "status": _status((f.get("status") or {}).get("text", "")),
        "aircraft": aircraft.get("code") or aircraft.get("text"),
        "baggageClaim": ((dest.get("info") or {}).get("baggage")),
        "delayMinutes": delay,
        "callsign": (f.get("identification") or {}).get("callsign"),
        "source": "fr24",
    }


@app.get("/health")
def health():
    return {"ok": True, "account": bool(os.environ.get("FR24_USER"))}


@app.get("/history/{number}/{day}")
def history(number: str, day: date, x_service_token: str | None = Header(default=None)):
    _require(x_service_token)
    try:
        found = _fetch(number.upper(), day)
    except HTTPException:
        raise
    except Exception as e:  # FR24 changed something; say so plainly
        raise HTTPException(status_code=502, detail=f"FR24 lookup failed: {type(e).__name__}: {e}")
    if not found or not found["departure"] or not found["arrival"] or not found["departureTime"]:
        raise HTTPException(status_code=404, detail=f"FR24 has no record of {number.upper()} on {day}.")
    return found
