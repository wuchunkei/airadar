"""
Boarding progress — check-in, gate open, boarding, final call, gate closing,
gate closed — straight from the departure airport's own flight information,
for the airports that publish it. No flight API carries these reliably; the
airport's departure boards do.

Each airport's board is fetched once and shared by every trip leaving from it,
cached for BOARD_TTL, and only asked for around departure (see trips.py).
Sources, checked live:
- HKG: the Airport Authority's flight information feed (also on DATA.GOV.HK).
- ICN: Incheon Airport's departures board, as its own website loads it.
- HND: Haneda's departures board, as its own website loads it.
- MFM: Macau Airport's real-time departures page.
The website-backed ones are not documented APIs and can change without notice;
a source that stops answering just yields nothing, never an error to the app.
"""
import html
import json
import re
import time
from datetime import datetime
from pathlib import Path

import httpx

CHECK_IN, GATE_OPEN, BOARDING, FINAL_CALL, GATE_CLOSING, GATE_CLOSED = (
    "CHECK_IN", "GATE_OPEN", "BOARDING", "FINAL_CALL", "GATE_CLOSING", "GATE_CLOSED")

AIRPORTS = ("HKG", "ICN", "HND", "MFM")
BOARD_TTL = 90  # seconds
_UA = {"User-Agent": "Mozilla/5.0 (compatible; Airadar flight tracker)"}

_ICAO_TO_IATA: dict[str, str] = json.loads((Path(__file__).parent / "data" / "airline_icao_iata.json").read_text())

# (airport, local date, local hour or None) -> (fetched at, {flight number: (phase, gate)})
_cache: dict[tuple, tuple[float, dict[str, tuple[str | None, str | None]]]] = {}


def normalize(number: str) -> str:
    """"CX 143", "CX0143", "cx143" -> "CX143": carrier, then the number without leading zeros."""
    s = re.sub(r"\s+", "", number or "").upper()
    m = re.fullmatch(r"([A-Z0-9]{2})(\d{1,5})([A-Z]?)", s)
    return f"{m.group(1)}{int(m.group(2))}{m.group(3)}" if m else s


async def lookup(http: httpx.AsyncClient, airport: str, number: str, scheduled: datetime) -> tuple[str | None, str | None] | None:
    """(phase or None, gate or None) for one departure; None when the board
    doesn't list it (or couldn't be read). `scheduled` is the airport-local time."""
    if airport not in AIRPORTS:
        return None
    key = (airport, scheduled.date(), scheduled.hour if airport == "ICN" else None)
    hit = _cache.get(key)
    if hit and time.monotonic() - hit[0] < BOARD_TTL:
        board = hit[1]
    else:
        try:
            board = await _FETCHERS[airport](http, scheduled)
        except Exception:
            board = hit[1] if hit else {}
        _cache[key] = (time.monotonic(), board)
        # Keep the cache from growing without bound.
        for k in [k for k, (t, _) in _cache.items() if time.monotonic() - t > 6 * 3600]:
            _cache.pop(k, None)
    return board.get(normalize(number))


def _gate(value) -> str | None:
    g = str(value or "").strip()
    return None if g in ("", "-", "--") else g


# --- Hong Kong ---------------------------------------------------------------

def _hkg_phase(status: str) -> str | None:
    s = status.strip().lower()
    if s.startswith("final call"):
        return FINAL_CALL
    if s.startswith("boarding"):
        return BOARDING
    if s.startswith("gate closed"):
        return GATE_CLOSED
    return None


async def _hkg(http: httpx.AsyncClient, scheduled: datetime) -> dict:
    url = "https://www.hongkongairport.com/flightinfo-rest/rest/flights/past"
    resp = await http.get(url, params={"date": scheduled.date().isoformat(), "lang": "en", "cargo": "false",
                                       "arrival": "false"}, headers=_UA, timeout=20)
    resp.raise_for_status()
    board = {}
    for day in resp.json():
        for f in day.get("list", []):
            entry = (_hkg_phase(f.get("status") or ""), _gate(f.get("gate")))
            for flight in f.get("flight", []):
                board[normalize(flight.get("no", ""))] = entry
    return board


# --- Incheon -----------------------------------------------------------------

_ICN_PHASE = {"GTO": GATE_OPEN, "BOR": BOARDING, "FIN": FINAL_CALL, "GTC": GATE_CLOSING}


async def _icn(http: httpx.AsyncClient, scheduled: datetime) -> dict:
    # The board answers for the hour asked about, but only inside a session the
    # site itself has started — without one it always returns the current hour.
    async with httpx.AsyncClient(headers=_UA, timeout=20, follow_redirects=True) as session:
        await session.get("https://www.airport.kr/ap_en/883/subview.do")
        day, hour = scheduled.strftime("%Y%m%d"), scheduled.strftime("%H")
        form = {"curDate": day, "daySel": day, "startTime": f"{hour}00", "endTime": f"{hour}59",
                "fromTime": f"{hour}00", "toTime": f"{hour}59", "siteId": "ap_en", "langSe": "en"}
        resp = await session.post("https://www.airport.kr/dep/ap_en/getDepPasSchList.do", data=form,
                                  headers={"X-Requested-With": "XMLHttpRequest"})
        resp.raise_for_status()
        rows = json.loads(resp.text).get("scheduleList", [])
    return {normalize(r.get("fnumber", "")): (_ICN_PHASE.get((r.get("remark") or "").upper()), _gate(r.get("gatenumber")))
            for r in rows}


# --- Haneda ------------------------------------------------------------------

def _hnd_phase(english: str) -> str | None:
    s = english.replace(" ", "").replace("-", "").lower()
    if s == "nowboarding":
        return BOARDING
    if s in ("gateclosed", "boardingcomplete"):
        return GATE_CLOSED
    if s == "checkin":
        return CHECK_IN
    return None


async def _hnd(http: httpx.AsyncClient, scheduled: datetime) -> dict:
    board = {}
    for kind in ("int", "dms"):
        resp = await http.get(f"https://tokyo-haneda.com/app_resource/flight/data/{kind}/hdacfdep.json",
                              headers=_UA, timeout=25)
        resp.raise_for_status()
        for f in resp.json().get("flight_info", []):
            # The board spans more than one day; only this day's departure counts.
            if not str(f.get("定刻", "")).startswith(scheduled.strftime("%Y/%m/%d")):
                continue
            remark = f.get("備考訳名称") or {}
            english = remark.get("en", "") if isinstance(remark, dict) else str(f.get("備考英名称", ""))
            entry = (_hnd_phase(english), _gate(f.get("ゲート番号コード")))
            for carrier in f.get("航空会社", []):
                iata = _ICAO_TO_IATA.get(str(carrier.get("ＡＬコード", "")).upper())
                digits = str(carrier.get("便名", "")).strip()
                if iata and digits.isdigit():
                    board[normalize(f"{iata}{digits}")] = entry
    return board


# --- Macau -------------------------------------------------------------------

def _mfm_phase(status: str) -> str | None:
    s = status.upper()
    if "FINAL CALL" in s or "LAST CALL" in s:
        return FINAL_CALL
    if "GATE CLOSED" in s:
        return GATE_CLOSED
    if "BOARDING" in s:
        return BOARDING
    if "GATE OPEN" in s:
        return GATE_OPEN
    if "CHECK-IN" in s and "OPEN" in s and "OPEN AT" not in s:
        return CHECK_IN
    return None


async def _mfm(http: httpx.AsyncClient, scheduled: datetime) -> dict:
    resp = await http.get("https://www.macau-airport.com/en/flights/real-time/departures", headers=_UA, timeout=25)
    resp.raise_for_status()
    board = {}
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", resp.text, re.S):
        cells = [html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", c))).strip()
                 for c in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
        cells = [c for c in cells if c]
        # time, airline + number, destination, number, terminal, gate, status, ...
        if len(cells) >= 7 and re.fullmatch(r"\d{2}:\d{2}", cells[0]) and re.fullmatch(r"[A-Z0-9]{2}\d{1,4}[A-Z]?", cells[3]):
            board[normalize(cells[3])] = (_mfm_phase(cells[6]), _gate(cells[5]))
    return board


_FETCHERS = {"HKG": _hkg, "ICN": _icn, "HND": _hnd, "MFM": _mfm}
