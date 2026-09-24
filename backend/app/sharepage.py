"""
The page a shared trip link opens in a browser: a boarding pass for the flight,
with who sent it and a way into the app. Self-contained HTML — no scripts, no
outside requests — so it renders the same in any in-app browser or link preview.
"""
import math
from datetime import datetime, timedelta, timezone
from html import escape
from zoneinfo import ZoneInfo

from .trips import _AIRPORTS, Trip

# (label, light-theme colour, dark-theme colour), same wording as the apps.
_STATUS = {
    "ON_TIME": ("On time", "#1F9D6B", "#5BD9A8"),
    "COMPLETED": ("Completed", "#6B6E78", "#B0ADBA"),
    "LANDED": ("Finished", "#1E6FD9", "#7FB8FF"),
    "DELAYED": ("Delayed", "#C46A12", "#FFB067"),
    "CANCELLED": ("Cancelled", "#C8372D", "#FF8A80"),
    "DIVERTED": ("Diverted", "#C8372D", "#FF8A80"),
    "BOARDING": ("Boarding", "#1E6FD9", "#7FB8FF"),
    "DEPARTED": ("Departed", "#1E6FD9", "#7FB8FF"),
    "IN_FLIGHT": ("In flight", "#1E6FD9", "#7FB8FF"),
    "SCHEDULED": ("Scheduled", "#6B6E78", "#B0ADBA"),
}
_EARLY = ("#1F9D6B", "#5BD9A8")
_LATE = ("#C46A12", "#FFB067")


def _span(minutes: int) -> str:
    return f"{minutes // 60}h {minutes % 60:02d}m" if minutes >= 60 else f"{minutes}m"


def _zone(iata: str) -> ZoneInfo | None:
    tz = (_AIRPORTS.get(iata) or {}).get("tz")
    return ZoneInfo(tz) if tz else None


def _gmt(zone: ZoneInfo | None, local: datetime) -> str:
    if zone is None:
        return ""
    offset = local.replace(tzinfo=zone).utcoffset() or timedelta()
    minutes = int(offset.total_seconds() // 60)
    sign = "+" if minutes >= 0 else "-"
    h, m = divmod(abs(minutes), 60)
    return f"GMT{sign}{h}" + (f":{m:02d}" if m else "")


def _utc(local: datetime, zone: ZoneInfo | None) -> datetime:
    local = local.replace(tzinfo=None)
    return local.replace(tzinfo=zone).astimezone(timezone.utc) if zone else local.replace(tzinfo=timezone.utc)


def _km(a: str, b: str) -> int | None:
    pa, pb = _AIRPORTS.get(a), _AIRPORTS.get(b)
    if not pa or not pb:
        return None
    lat1, lon1, lat2, lon2 = map(math.radians, (float(pa["lat"]), float(pa["lon"]), float(pb["lat"]), float(pb["lon"])))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return round(2 * 6371 * math.asin(math.sqrt(h)))


def _city(iata: str) -> str:
    row = _AIRPORTS.get(iata) or {}
    return row.get("city") or row.get("name") or ""


def _arc(progress: float | None, colour_var: str) -> str:
    """The route as a bowed arc: dashed until flown, the flown part solid, the
    plane where it is. `progress` None before departure, 0-1 in the air or after."""
    p0, p1, p2 = (8.0, 46.0), (100.0, -6.0), (192.0, 46.0)
    t = 0.0 if progress is None else max(0.0, min(1.0, progress))

    def at(u: float) -> tuple[float, float]:
        return ((1 - u) ** 2 * p0[0] + 2 * (1 - u) * u * p1[0] + u ** 2 * p2[0],
                (1 - u) ** 2 * p0[1] + 2 * (1 - u) * u * p1[1] + u ** 2 * p2[1])

    x, y = at(t)
    dx = 2 * (1 - t) * (p1[0] - p0[0]) + 2 * t * (p2[0] - p1[0])
    dy = 2 * (1 - t) * (p1[1] - p0[1]) + 2 * t * (p2[1] - p1[1])
    angle = math.degrees(math.atan2(dy, dx)) + 90
    path = f"M{p0[0]},{p0[1]} Q{p1[0]},{p1[1]} {p2[0]},{p2[1]}"
    flown = "" if progress is None else (
        f'<path d="{path}" pathLength="100" fill="none" stroke="var({colour_var})" stroke-width="2.5" '
        f'stroke-linecap="round" stroke-dasharray="{t * 100:.2f} 200"/>')
    plane = ("M0,-7 L1.6,-2 L8,1.2 L8,3 L1.6,1.6 L1.2,5.2 L3,6.6 L3,7.8 L0,7 L-3,7.8 L-3,6.6 "
             "L-1.2,5.2 L-1.6,1.6 L-8,3 L-8,1.2 L-1.6,-2 Z")
    return f"""<svg class="arc" viewBox="0 0 200 54" aria-hidden="true">
  <path d="{path}" fill="none" stroke="var(--rule)" stroke-width="2" stroke-dasharray="3 5" stroke-linecap="round"/>
  {flown}
  <circle cx="{p0[0]}" cy="{p0[1]}" r="3.5" fill="var(--ink)"/>
  <circle cx="{p2[0]}" cy="{p2[1]}" r="3.5" fill="none" stroke="var(--ink)" stroke-width="2"/>
  <g transform="translate({x:.2f} {y:.2f}) rotate({angle:.1f})"><path d="{plane}" fill="var({colour_var})"/></g>
</svg>"""


def render(t: Trip, sender: str, sender_tint: str, token: str, now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    status = t.status.value if hasattr(t.status, "value") else str(t.status)
    label, light, dark = _STATUS.get(status, _STATUS["SCHEDULED"])

    dep_zone, arr_zone = _zone(t.departure), _zone(t.arrival)
    dep_moved = max(0, t.delayMinutes)
    arr_moved = t.arrivalDelayMinutes if t.arrivalDelayMinutes is not None else dep_moved
    dep_local = t.departureTime.replace(tzinfo=None) + timedelta(minutes=dep_moved)
    arr_local = t.arrivalTime.replace(tzinfo=None) + timedelta(minutes=arr_moved)
    dep_at, arr_at = _utc(dep_local, dep_zone), _utc(arr_local, arr_zone)

    landed = status in ("LANDED", "COMPLETED") or now >= arr_at
    stopped = status in ("CANCELLED", "DIVERTED")
    if landed and t.arrivalDelayMinutes is not None and not stopped:
        d = t.arrivalDelayMinutes
        label = "Landed · " + (f"{_span(-d)} early" if d < 0 else f"{_span(d)} late" if d > 0 else "on time")
        light, dark = _EARLY if d <= 0 else _LATE
    elif not landed and not stopped and t.delayMinutes > 0:
        label = f"{label} · {_span(t.delayMinutes)} late"
        light, dark = _LATE

    if stopped or now < dep_at:
        progress = None
    elif landed:
        progress = 1.0
    else:
        total = (arr_at - dep_at).total_seconds()
        progress = (now - dep_at).total_seconds() / total if total > 0 else 0.0

    minutes = max(0, int((arr_at - dep_at).total_seconds() // 60))
    km = _km(t.departure, t.arrival)

    def time_block(title: str, local: datetime, scheduled: datetime, moved: int, zone: ZoneInfo | None, align: str) -> str:
        was = f'<s>{scheduled.strftime("%H:%M")}</s>' if moved else ""
        cls = "early" if moved < 0 else "late" if moved > 0 else ""
        return f"""<div class="when {align}">
  <div class="k">{title}</div>
  <div class="t">{was}<span class="{cls}">{local.strftime("%H:%M")}</span></div>
  <div class="z">{escape(_gmt(zone, local))} · {local.strftime("%a %-d %b")}</div>
</div>"""

    def place(code: str, terminal: str | None, gate: str | None) -> str:
        bits = [f"T{escape(terminal)}" if terminal else "", f"Gate {escape(gate)}" if gate else ""]
        return " · ".join(b for b in bits if b) or "—"

    facts = [
        ("Date", t.departureTime.strftime("%a, %-d %b %Y")),
        ("Duration", _span(minutes)),
        ("Distance", f"{km:,} km" if km else None),
        ("Aircraft", escape(t.aircraft) if t.aircraft else None),
        (f"From {escape(t.departure)}", place(t.departure, t.departureTerminal, t.departureGate)),
        (f"To {escape(t.arrival)}", place(t.arrival, t.arrivalTerminal, t.arrivalGate)),
        ("Baggage belt", escape(t.baggageClaim) if t.baggageClaim else None),
    ]
    fact_html = "".join(f'<div class="f"><div class="k">{k}</div><div class="v">{v}</div></div>' for k, v in facts if v)

    dep_city, arr_city = _city(t.departure), _city(t.arrival)
    name = escape(sender)
    airline = escape(t.airlineName or "")
    number = escape(t.flightNumber)
    route_words = f"{escape(dep_city or t.departure)} → {escape(arr_city or t.arrival)}"
    summary = f"{t.departureTime.strftime('%a %-d %b')} · departs {dep_local.strftime('%H:%M')} · {label}"

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>{number} · {route_words}</title>
<meta property="og:title" content="{number} · {route_words}">
<meta property="og:description" content="{name} shared a flight · {escape(summary)}">
<meta property="og:site_name" content="Airadar">
<meta name="twitter:card" content="summary">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#f3f4f7" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0b0d12" media="(prefers-color-scheme: dark)">
<style>
  :root {{
    --bg: #f3f4f7; --glow: rgba(30,111,217,.10); --card: #ffffff; --ink: #14161b; --muted: #6b6e78;
    --rule: #d5d8df; --soft: #f1f2f5; --shadow: 0 1px 2px rgba(20,22,27,.06), 0 12px 40px rgba(20,22,27,.10);
    --status: {light}; --early: {_EARLY[0]}; --late: {_LATE[0]}; --sender: {sender_tint};
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #0b0d12; --glow: rgba(127,184,255,.12); --card: #171a21; --ink: #f2f3f6; --muted: #8d919d;
      --rule: #333844; --soft: #1f232c; --shadow: 0 1px 2px rgba(0,0,0,.4), 0 16px 48px rgba(0,0,0,.45);
      --status: {dark}; --early: {_EARLY[1]}; --late: {_LATE[1]};
    }}
  }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; }}
  body {{
    min-height: 100vh; background: radial-gradient(120% 60% at 50% -10%, var(--glow), transparent 60%), var(--bg);
    color: var(--ink); font: 15px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased; font-variant-numeric: tabular-nums;
    padding: max(28px, env(safe-area-inset-top)) 18px max(28px, env(safe-area-inset-bottom));
    display: flex; justify-content: center;
  }}
  main {{ width: 100%; max-width: 400px; }}
  .from {{ display: flex; align-items: center; gap: 10px; margin: 4px 4px 16px; }}
  .avatar {{ width: 34px; height: 34px; border-radius: 50%; background: var(--sender); color: #fff; font-weight: 700;
            display: grid; place-items: center; flex: none; font-size: 15px; }}
  .from b {{ display: block; font-size: 15px; }}
  .from span {{ color: var(--muted); font-size: 13px; }}
  .pass {{ background: var(--card); border-radius: 28px; box-shadow: var(--shadow); overflow: hidden; }}
  .top {{ padding: 20px 22px 18px; }}
  .head {{ display: flex; justify-content: space-between; align-items: center; gap: 12px; }}
  .airline {{ color: var(--muted); font-size: 13px; font-weight: 600; letter-spacing: .02em; overflow: hidden;
             text-overflow: ellipsis; white-space: nowrap; }}
  .number {{ font-weight: 700; font-size: 13px; letter-spacing: .04em; background: var(--soft); padding: 5px 10px;
            border-radius: 999px; flex: none; }}
  .route {{ display: grid; grid-template-columns: auto 1fr auto; align-items: end; gap: 8px; margin-top: 18px; }}
  .code {{ font-size: 42px; font-weight: 800; letter-spacing: -.02em; line-height: 1; }}
  .city {{ color: var(--muted); font-size: 13px; margin-top: 6px; max-width: 110px; }}
  .right {{ text-align: right; }}
  .right .city {{ margin-left: auto; }}
  .mid {{ text-align: center; padding-bottom: 20px; }}
  .arc {{ width: 100%; height: auto; display: block; overflow: visible; }}
  .dur {{ color: var(--muted); font-size: 12px; font-weight: 600; margin-top: -2px; }}
  .times {{ display: grid; grid-template-columns: 1fr 1fr; margin-top: 18px; }}
  .when .k, .f .k {{ color: var(--muted); font-size: 11px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; }}
  .when .t {{ font-size: 24px; font-weight: 700; margin-top: 3px; }}
  .when .t s {{ color: var(--muted); font-size: 15px; font-weight: 500; margin-right: 6px; }}
  .when .z {{ color: var(--muted); font-size: 12px; margin-top: 2px; }}
  .early {{ color: var(--early); }} .late {{ color: var(--late); }}
  .status {{ display: inline-flex; align-items: center; gap: 7px; margin-top: 18px; padding: 7px 12px 7px 10px;
            border-radius: 999px; font-size: 13px; font-weight: 700; color: var(--status);
            background: color-mix(in srgb, var(--status) 14%, transparent); }}
  .status i {{ width: 7px; height: 7px; border-radius: 50%; background: var(--status); }}
  .tear {{ position: relative; height: 22px; }}
  .tear::before, .tear::after {{ content: ""; position: absolute; top: 0; width: 22px; height: 22px; border-radius: 50%;
                                background: var(--bg); }}
  .tear::before {{ left: -11px; }} .tear::after {{ right: -11px; }}
  .tear hr {{ position: absolute; left: 20px; right: 20px; top: 10px; margin: 0; border: 0;
             border-top: 2px dashed var(--rule); }}
  .stub {{ display: grid; grid-template-columns: 1fr 1fr; gap: 16px 18px; padding: 8px 22px 22px; }}
  .f .v {{ font-size: 15px; font-weight: 600; margin-top: 3px; }}
  .open {{ display: block; text-align: center; margin-top: 18px; padding: 16px; border-radius: 16px; color: #fff;
          font-weight: 700; font-size: 16px; text-decoration: none;
          background: linear-gradient(180deg, #4c8dff, #2f6fe8); box-shadow: 0 8px 24px rgba(47,111,232,.35); }}
  .note {{ text-align: center; color: var(--muted); font-size: 12px; margin-top: 12px; }}
  .brand {{ text-align: center; color: var(--muted); font-size: 12px; font-weight: 700; letter-spacing: .12em;
           text-transform: uppercase; margin-top: 26px; opacity: .7; }}
</style>
</head>
<body>
<main>
  <div class="from">
    <div class="avatar">{escape(sender[:1].upper())}</div>
    <div><b>{name}</b><span>shared a flight with you</span></div>
  </div>

  <section class="pass">
    <div class="top">
      <div class="head"><div class="airline">{airline}</div><div class="number">{number}</div></div>
      <div class="route">
        <div><div class="code">{escape(t.departure)}</div><div class="city">{escape(dep_city)}</div></div>
        <div class="mid">{_arc(progress, "--status")}<div class="dur">{_span(minutes)}</div></div>
        <div class="right"><div class="code">{escape(t.arrival)}</div><div class="city">{escape(arr_city)}</div></div>
      </div>
      <div class="times">
        {time_block("Departs", dep_local, t.departureTime, dep_moved, dep_zone, "")}
        {time_block("Arrives", arr_local, t.arrivalTime, arr_moved, arr_zone, "right")}
      </div>
      <div class="status"><i></i>{escape(label)}</div>
    </div>
    <div class="tear"><hr></div>
    <div class="stub">{fact_html}</div>
  </section>

  <a class="open" href="airadar://s/{escape(token)}">Open in Airadar</a>
  <div class="note">Times are local to each airport.</div>
  <div class="brand">Airadar</div>
</main>
</body>
</html>"""
