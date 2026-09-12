"""
Umetrip (航旅纵横) — fallback status source, reached through the vendored
fuck-ume-trip client. That client speaks a private, reverse-engineered protocol
frozen at a 2019 app build; treat every failure here as "Umetrip changed
something", never as a bug in the flight.

The vendored code is synchronous (requests), so it runs in a worker thread.
"""

import asyncio
import os
import sys
from datetime import date, datetime
from pathlib import Path

from .schema import Flight, FlightStatus, flight_id

VENDOR = Path(__file__).resolve().parent.parent / "vendor" / "fuck-ume-trip"


class UmetripError(Exception):
    pass


def enabled() -> bool:
    return os.environ.get("UMETRIP_ENABLED", "true").lower() not in ("0", "false", "no")


_api = None


def _client():
    """Import lazily: the module loads libumetrip.so on import and we only pay for that once."""
    global _api
    if _api is None:
        if not VENDOR.is_dir():
            raise UmetripError("vendor/fuck-ume-trip is missing — init the git submodule.")
        sys.path.insert(0, str(VENDOR))
        try:
            import api  # noqa: E402  (vendored module)
            import pb  # noqa: E402
        except OSError as e:
            raise UmetripError(f"libumetrip.so failed to load: {e}") from e
        _api = (api.Api(), pb)
    return _api


def _lookup_sync(number: str, day: date) -> Flight:
    client, pb = _client()
    reply = client.get_flight_status_by_code(number.upper(), day.isoformat())

    if reply.ret != 0 or reply.HasField("error"):
        msg = reply.error.message if reply.HasField("error") else f"ret={reply.ret}"
        raise UmetripError(f"Umetrip gateway refused the request: {msg}")

    wrap = reply.payload
    if wrap.errcode != 0:
        raise UmetripError(f"Umetrip: {wrap.errmsg or f'errcode {wrap.errcode}'}")

    body = pb.S2cGetFlightStatusOrFlightList.FromString(wrap.responseBody)
    if not body.isSuccess or not body.flightStatusList:
        raise UmetripError(f"Umetrip has no record of {number.upper()} on {day}.")

    return _parse(body.flightStatusList[0], number, day)


async def flight(number: str, day: date) -> Flight:
    return await asyncio.to_thread(_lookup_sync, number, day)


# ---- parsing ---------------------------------------------------------------

_STATUS = {
    "取消": FlightStatus.CANCELLED,
    "备降": FlightStatus.DIVERTED,
    "返航": FlightStatus.DIVERTED,
    "到达": FlightStatus.LANDED,
    "起飞": FlightStatus.IN_FLIGHT,
    "登机": FlightStatus.BOARDING,
    "延误": FlightStatus.DELAYED,
    "计划": FlightStatus.SCHEDULED,
}


def _status(text: str, delay: int) -> FlightStatus:
    for needle, status in _STATUS.items():
        if needle in text:
            return status
    return FlightStatus.DELAYED if delay > 0 else FlightStatus.SCHEDULED


def _combine(day: str, clock: str) -> datetime | None:
    """Umetrip splits date ('2026-09-21') and time ('02:30')."""
    if not day or not clock:
        return None
    try:
        return datetime.strptime(f"{day} {clock[:5]}", "%Y-%m-%d %H:%M")
    except ValueError:
        return None


def _parse(bean, number: str, day: date) -> Flight:
    number = number.upper()
    dep, arr = bean.deptCityCode.upper(), bean.destCityCode.upper()
    if not dep or not arr:
        raise UmetripError(f"Umetrip record for {number} has no route.")

    std = _combine(bean.deptFlightDate, bean.std)
    sta = _combine(bean.destFlightDate or bean.deptFlightDate, bean.sta)
    if not std or not sta:
        raise UmetripError(f"Umetrip record for {number} has no scheduled times.")

    delay = max(int(bean.deptDelayTime or 0), 0)
    return Flight(
        id=flight_id(number, day),
        flightNumber=number,
        airlineName=bean.airlineName or number[:2],
        departure=dep,
        arrival=arr,
        departureTerminal=bean.deptTerminal or None,
        arrivalTerminal=bean.destTerminal or None,
        departureGate=bean.deptGate or None,
        arrivalGate=None,
        departureTime=std,
        arrivalTime=sta,
        status=_status(bean.flightStatus or "", delay),
        aircraft=None,
        baggageClaim=bean.carousel or None,
        delayMinutes=delay,
        callsign=None,
        source="umetrip",
    )
