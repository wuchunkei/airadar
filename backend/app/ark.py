"""Volcengine Ark (火山方舟) -- an LLM platform with a web-search-capable
model, used here strictly as a manually-triggered research assistant. It is
never a source of truth for a flight's own facts (route, schedule, status):
those stay with feed.py's real sources (AirLabs, AeroDataBox, adsbdb) and,
failing those, the traveller's own manual entry plus community.py's review
queue. Nothing here is wired into that pipeline -- these functions exist to
be called by hand while this integration is still being shaped.

Two uses:

  - ask_flight_context(): a route's historical on-time/delay reputation,
    plus the actual historical weather at each airport around the
    scheduled times. Both are genuinely well-suited to a web search --
    published on-time-performance stats and public weather archives exist
    for almost any route/airport/date -- unlike a specific flight
    instance's exact minute-by-minute facts, which is what feed.py's real
    sources are for.
  - ask_track_points(): experimental. Asks whether real lat/lon ADS-B
    track points for one specific flight instance are actually findable
    on the web. Expected answer, most of the time, is "no" -- that data
    lives behind paid FlightAware/FlightRadar24 exports, not on any page
    a web search reaches -- but this asks the real API rather than assume.

Whatever either of these returns is a citation-backed guess, not a
verified fact. If this is ever wired into the app for real, its output
must still flow through the same manual-entry + community-review gate as
any other unverified source -- never presented as confirmed.
"""

import json
import os
from datetime import date, datetime

import airportsdata
import httpx

_AIRPORTS = airportsdata.load("IATA")

# cn-beijing, matching the console region this key was issued in. Ark's base
# URL is region-specific; if the key turns out to live in a different
# region this will need to change to match.
ARK_BASE_URL = "https://ark.cn-beijing.volces.com/api/v3"


class ArkError(Exception):
    pass


def _key() -> str:
    key = os.environ.get("ARK_API_KEY", "").strip()
    if not key:
        raise ArkError("ARK_API_KEY is not set on the server.")
    return key


def _model() -> str:
    # A model or Bot endpoint id from the Ark console -- specifically
    # whichever one actually has the web-search plugin attached. There is
    # no safe default: a bare base model has no internet access at all, so
    # this has to be filled in by hand from the console.
    model = os.environ.get("ARK_MODEL", "").strip()
    if not model:
        raise ArkError("ARK_MODEL is not set on the server (the model/bot endpoint id with web search attached).")
    return model


def _place(iata: str) -> str:
    row = _AIRPORTS.get(iata.upper())
    if not row:
        return iata.upper()
    return f"{row.get('city') or row['name']}, {row.get('country')} ({iata.upper()})"


async def _chat(client: httpx.AsyncClient, prompt: str) -> str:
    """One call to Ark's OpenAI-compatible chat completions endpoint.
    Raises ArkError with the raw response text on anything unexpected --
    deliberately not swallowed, since this integration is still being
    verified against the real API's actual shape."""
    resp = await client.post(
        f"{ARK_BASE_URL}/chat/completions",
        headers={"Authorization": f"Bearer {_key()}", "Content-Type": "application/json"},
        json={
            "model": _model(),
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You are a research assistant helping verify flight information. Search the "
                        "web for real, cited information. If you cannot find a specific fact, say so "
                        "explicitly -- null is always better than a guess. Answer only with a single "
                        "JSON object and nothing else, no prose outside it, no markdown fence."
                    ),
                },
                {"role": "user", "content": prompt},
            ],
        },
        timeout=60,
    )
    if resp.status_code != 200:
        raise ArkError(f"Ark answered HTTP {resp.status_code}: {resp.text[:800]}")
    data = resp.json()
    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError) as e:
        raise ArkError(f"Ark's response didn't have the expected shape: {data}") from e


def _parse_json(text: str) -> dict:
    """Ark, like most chat models, sometimes wraps JSON in a ```json fence
    even when told not to -- stripped here rather than re-prompted for. A
    reply that still isn't parseable JSON comes back as {"raw": text} so
    the caller can see exactly what happened instead of a swallowed error."""
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`")
        if cleaned.lower().startswith("json"):
            cleaned = cleaned[4:]
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        return {"raw": text}


async def ask_flight_context(
    client: httpx.AsyncClient,
    flight_number: str,
    dep_iata: str,
    arr_iata: str,
    dep_local: datetime,
    arr_local: datetime,
) -> dict:
    """A route's historical delay reputation, plus real historical weather
    at each end around the scheduled times."""
    prompt = (
        f"Flight {flight_number}, from {_place(dep_iata)} to {_place(arr_iata)}.\n"
        f"Scheduled departure: {dep_local.isoformat()} local time at {dep_iata.upper()}.\n"
        f"Scheduled arrival: {arr_local.isoformat()} local time at {arr_iata.upper()}.\n\n"
        "Search the web and answer with a single JSON object with exactly these keys:\n"
        '  "delay_history": a short summary of this flight number\'s or route\'s typical '
        "on-time performance / delay pattern, citing what you found, or null if nothing;\n"
        '  "departure_weather": the actual historical weather at the departure airport around '
        "that date and time (conditions, temperature, wind, visibility), or null if unavailable;\n"
        '  "arrival_weather": the same for the arrival airport around the scheduled arrival time, or null;\n'
        '  "sources": a list of URLs you actually used, or an empty list.\n'
        "Use null, not a guess, for anything you could not actually find."
    )
    return _parse_json(await _chat(client, prompt))


async def ask_track_points(client: httpx.AsyncClient, flight_number: str, dep_iata: str, arr_iata: str, day: date) -> dict:
    """Experimental, not a real feature yet: asks whether real lat/lon
    track points for this specific flight instance are findable at all."""
    prompt = (
        f"Flight {flight_number} from {dep_iata.upper()} to {arr_iata.upper()} on {day.isoformat()}.\n\n"
        "Search the web for the ACTUAL recorded flight track (latitude/longitude/altitude over time) "
        "for this specific flight on this specific date -- not a typical route, not a great-circle "
        "approximation, only real recorded ADS-B track points if you can genuinely find them published "
        "somewhere. Answer with a single JSON object:\n"
        '  "found": true or false;\n'
        '  "points": a list of {"time", "lat", "lon", "altitude_ft"} objects if found, else an empty list;\n'
        '  "source": the URL you found them at, or null;\n'
        '  "note": a short explanation, especially if found is false.\n'
        "Do not fabricate points -- if you cannot find real recorded ones, found must be false and points empty."
    )
    return _parse_json(await _chat(client, prompt))
