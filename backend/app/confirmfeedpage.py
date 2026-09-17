"""The /confirm_feed admin console: sign in with Google, restricted to
ADMIN_EMAIL by every API call it makes (community.py's require_admin) —
this page itself has no server-side gate, the JSON calls behind it do.
{{GOOGLE_CLIENT_ID}} is filled in at request time in main.py, the same
existing Web OAuth client the phone app's own sign-in already verifies
against."""

PAGE = """<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Airadar · Confirm feed</title>
<script src="https://accounts.google.com/gsi/client" async defer></script>
<style>
:root{--bg:#0f1115;--fg:#eee;--mute:#9aa3b2;--card:#181b21;--line:#2a2f3a;--green:#2fbf71;--red:#e5484d;--amber:#e0a63c}
@media (prefers-color-scheme: light){:root{--bg:#f4f5f7;--fg:#111;--mute:#5b6270;--card:#fff;--line:#d9dde3}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;padding:24px}
h1{font-size:20px;margin:0 0 20px}
#signin{display:flex;flex-direction:column;align-items:center;gap:16px;padding:80px 0}
#board{display:none;grid-template-columns:repeat(4,1fr);gap:16px}
@media (max-width:900px){#board{grid-template-columns:1fr;display:none}#board.open{display:grid}}
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
#denied{display:none;color:var(--red);padding:40px 0;text-align:center}
.empty{color:var(--mute);font-size:12px}
</style>
<h1>Confirm feed — community review</h1>
<div id="signin">
  <div id="g_id_button"></div>
</div>
<p id="denied">Not authorized.</p>
<div id="board">
  <div class="col"><h2>Pending</h2><div id="col-pending"></div></div>
  <div class="col"><h2>Confirmed</h2><div id="col-confirmed"></div></div>
  <div class="col"><h2>Rejected</h2><div id="col-rejected"></div></div>
  <div class="col"><h2>Expired</h2><div id="col-expired"></div></div>
</div>
<script>
let token = null;

google.accounts.id.initialize({ client_id: "{{GOOGLE_CLIENT_ID}}", callback: onSignIn });
google.accounts.id.renderButton(document.getElementById("g_id_button"), { theme: "outline", size: "large" });

async function onSignIn(response) {
  const r = await fetch("/auth/google", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ idToken: response.credential, device: "confirm_feed_web" }),
  });
  if (!r.ok) { document.getElementById("denied").style.display = "block"; return; }
  const data = await r.json();
  token = data.accessToken;
  document.getElementById("signin").style.display = "none";
  document.getElementById("board").style.display = "grid";
  loadAll();
}

async function api(path, options = {}) {
  const r = await fetch(path, { ...options, headers: { ...(options.headers || {}), Authorization: "Bearer " + token } });
  if (r.status === 403) {
    document.getElementById("board").style.display = "none";
    document.getElementById("denied").style.display = "block";
    throw new Error("not authorized");
  }
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

async function loadColumn(name) {
  const items = await api(`/community/admin/queue?column=${name}`);
  const el = document.getElementById("col-" + name);
  el.innerHTML = items.length ? items.map(i => card(i, name)).join("") : '<p class="empty">Nothing here.</p>';
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
