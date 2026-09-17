"""The /confirm_feed admin console: sign in with Google, restricted to
ADMIN_EMAIL by every API call it makes (community.py's require_admin) —
this page itself has no server-side gate, the JSON calls behind it do.
{{GOOGLE_CLIENT_ID}} is filled in at request time in main.py, the same
existing Web OAuth client the phone app's own sign-in already verifies
against.

Opening the page shows nothing but a centred "Continue with Google"
button — no heading, no board, not even a peek at it — until the signed-in
account is actually verified as ADMIN_EMAIL. auto_select is off, so this
never happens silently from an existing Google browser session; a fresh
click is the only way in, every time."""

PAGE = """<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Airadar · Confirm feed</title>
<script src="https://accounts.google.com/gsi/client" async defer onload="onGsiReady()" onerror="onGsiFailed()"></script>
<style>
:root{--bg:#0f1115;--fg:#eee;--mute:#9aa3b2;--card:#181b21;--line:#2a2f3a;--green:#2fbf71;--red:#e5484d;--amber:#e0a63c}
@media (prefers-color-scheme: light){:root{--bg:#f4f5f7;--fg:#111;--mute:#5b6270;--card:#fff;--line:#d9dde3}}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
h1{font-size:20px;margin:0 0 20px}
#signin{display:flex;min-height:100vh;align-items:center;justify-content:center}
#app{display:none;padding:24px}
#denied,#loaderror{display:none;min-height:100vh;align-items:center;justify-content:center;color:var(--red);font-size:15px;text-align:center;padding:24px}
#board{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}
@media (max-width:900px){#board{grid-template-columns:1fr}}
.col h2{font-size:14px;text-transform:uppercase;letter-spacing:.04em;color:var(--mute);margin:0 0 10px}
.col{min-width:0}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px;margin-bottom:10px;font-size:13px}
.card .num{font-weight:700;font-size:15px}
.card .route{color:var(--mute);margin:4px 0}
.card .tally{margin:6px 0}
.card .tally .a{color:var(--green)}.card .tally .r{color:var(--red)}
.card .btns{display:flex;gap:6px;margin-top:8px}
button{border:1px solid var(--line);background:transparent;color:var(--fg);border-radius:8px;padding:6px 10px;font-size:12px;cursor:pointer}
button.confirm{border-color:var(--green);color:var(--green)}
button.reject{border-color:var(--red);color:var(--red)}
button.release{border-color:var(--amber);color:var(--amber)}
.empty{color:var(--mute);font-size:12px}
</style>
<div id="signin"><div id="g_id_button"></div></div>
<div id="denied">Not authorized.</div>
<div id="loaderror">Couldn't reach Google's sign-in service — check that this device/network can load accounts.google.com (it's blocked on some networks without a VPN).</div>
<div id="app">
  <h1>Confirm feed — community review</h1>
  <div id="board">
    <div class="col"><h2>Pending</h2><div id="col-pending"></div></div>
    <div class="col"><h2>Confirmed</h2><div id="col-confirmed"></div></div>
    <div class="col"><h2>Rejected</h2><div id="col-rejected"></div></div>
    <div class="col"><h2>Expired</h2><div id="col-expired"></div></div>
  </div>
</div>
<script>
let token = null;
let gsiReady = false;

// The library tag is async/defer -- it can genuinely still be loading by
// the time this script block runs, so initializing here directly raced it
// and, on a slow or blocked connection, lost: `google` was undefined,
// the one call threw, and the whole rest of this script silently never
// ran -- a plain dark page with nothing on it and no visible error at all.
// Waiting for the library's own onload (below) fixes the ordering; the
// timeout below covers the other real case, where the network genuinely
// can't reach accounts.google.com at all (common without a VPN in some
// regions) and onload never fires.
function onGsiReady() {
  gsiReady = true;
  // auto_select disabled on purpose: opening this page must always land
  // on the sign-in button, never silently authenticate from an existing
  // Google browser session — a fresh click is the only way in, every time.
  google.accounts.id.initialize({ client_id: "{{GOOGLE_CLIENT_ID}}", callback: onSignIn, auto_select: false, cancel_on_tap_outside: true });
  google.accounts.id.renderButton(document.getElementById("g_id_button"), { theme: "filled_black", size: "large", text: "continue_with" });
}

function onGsiFailed() {
  document.getElementById("signin").style.display = "none";
  document.getElementById("loaderror").style.display = "flex";
}

setTimeout(() => { if (!gsiReady) onGsiFailed(); }, 6000);

function showDenied() {
  document.getElementById("signin").style.display = "none";
  document.getElementById("denied").style.display = "flex";
}

async function onSignIn(response) {
  const r = await fetch("/auth/google", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ idToken: response.credential, device: "confirm_feed_web" }),
  });
  if (!r.ok) { showDenied(); return; }
  const data = await r.json();
  token = data.accessToken;
  // The email has to check out as ADMIN_EMAIL before anything past the
  // sign-in button is ever shown — this call exists purely to verify that.
  const check = await fetch("/community/admin/queue?column=pending", { headers: { Authorization: "Bearer " + token } });
  if (!check.ok) { showDenied(); return; }
  document.getElementById("signin").style.display = "none";
  document.getElementById("app").style.display = "block";
  renderColumn("pending", await check.json());
  loadColumn("confirmed"); loadColumn("rejected"); loadColumn("expired");
}

async function api(path, options = {}) {
  const r = await fetch(path, { ...options, headers: { ...(options.headers || {}), Authorization: "Bearer " + token } });
  if (r.status === 403) { showDenied(); throw new Error("not authorized"); }
  return r.json();
}

function card(item, column) {
  const dep = item.departureTime.replace("T", " ").slice(0, 16);
  const arr = item.arrivalTime.replace("T", " ").slice(0, 16);
  let btns = "";
  if (column === "pending") {
    btns = `<button class="confirm" onclick="act('${item.id}','confirm')">Confirm</button>
            <button class="reject" onclick="act('${item.id}','reject')">Reject</button>`;
  } else if (column === "expired") {
    btns = `<button class="release" onclick="act('${item.id}','release')">Release</button>
            <button class="confirm" onclick="act('${item.id}','confirm')">Confirm</button>
            <button class="reject" onclick="act('${item.id}','reject')">Reject</button>`;
  }
  return `<div class="card">
    <div class="num">${item.flightNumber} <span style="color:var(--mute);font-weight:400">${item.airlineName}</span></div>
    <div class="route">${item.departure} → ${item.arrival}</div>
    <div class="route">${dep} → ${arr}</div>
    <div class="tally"><span class="a">${item.approveCount} approve</span> · <span class="r">${item.rejectCount} reject</span>${item.boosted ? " · boosted" : ""}</div>
    <div class="btns">${btns}</div>
  </div>`;
}

function renderColumn(name, items) {
  const el = document.getElementById("col-" + name);
  el.innerHTML = items.length ? items.map(i => card(i, name)).join("") : '<p class="empty">Nothing here.</p>';
}

async function loadColumn(name) {
  renderColumn(name, await api(`/community/admin/queue?column=${name}`));
}

function loadAll() {
  ["pending", "confirmed", "rejected", "expired"].forEach(loadColumn);
}

async function act(id, action) {
  await api(`/community/admin/${id}/${action}`, { method: "POST" });
  loadAll();
}
</script>
"""
