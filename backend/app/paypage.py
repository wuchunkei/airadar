"""The /pay page: four buttons, Stripe behind two of them, and the hover choreography."""

STYLE = """<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#000;--fg:#f2f2f2;--mute:#9aa3b2;--card:#101216;--line:#2a2f3a;--field:#0a0b0e;
  --gold-hi:#ffd24a;--red:#b3261e;--red-bg:#2a0c0c;--red-card:#3a1010;
  --crack-a:rgba(255,255,255,.55);--crack-b:rgba(0,0,0,.9);--stone:#c9c9c9}
@media (prefers-color-scheme: light){:root{--bg:#fff;--fg:#111;--mute:#5b6270;--card:#f4f5f7;--line:#d9dde3;--field:#fff;
  --red-bg:#ffecec;--red-card:#ffd6d6;--crack-a:rgba(0,0,0,.55);--crack-b:rgba(255,255,255,.9);--stone:#555}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;display:flex;align-items:center;justify-content:center;transition:background 1.5s}
main{width:min(640px,94vw);text-align:center}
h1{margin:0 0 24px;font-size:28px}p.sub{color:var(--mute);margin:0 0 28px}
/* 1 2 / 3 4 */
.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}
@media (max-width:480px){.grid{grid-template-columns:1fr}}
.btn{position:relative;display:block;width:100%;min-height:96px;padding:18px 16px;border-radius:20px;border:2px solid var(--line);background:var(--card);color:var(--fg);font-size:18px;font-weight:600;cursor:pointer;text-decoration:none;transition:border-color .2s,background .2s,filter 1.2s,color 1.2s}
.btn small{display:block;font-weight:400;color:var(--mute);font-size:13px;margin-top:4px}
/* Hover: the frame simply brightens. */
.btn:hover{border-color:var(--fg)}
/* forgot: the page reddens; the other three turn to stone and crack */
body.forgot{background:var(--red-bg)}
.forgot-btn.hot{border-color:var(--red);background:var(--red-card)}
.stone{filter:grayscale(1) contrast(.85) brightness(.8);color:var(--stone)}
.stone small{color:var(--stone)}
.stone::after{content:"";position:absolute;inset:0;border-radius:18px;pointer-events:none;opacity:0;
  background:
    linear-gradient(112deg,transparent 46.5%,var(--crack-a) 47.2%,var(--crack-b) 48%,transparent 49.2%),
    linear-gradient(38deg,transparent 28%,var(--crack-a) 28.8%,var(--crack-b) 29.6%,transparent 30.8%),
    linear-gradient(158deg,transparent 60%,var(--crack-a) 60.7%,var(--crack-b) 61.4%,transparent 62.6%),
    linear-gradient(78deg,transparent 74%,var(--crack-a) 74.6%,var(--crack-b) 75.3%,transparent 76.4%),
    linear-gradient(135deg,transparent 15%,var(--crack-a) 15.6%,var(--crack-b) 16.2%,transparent 17.2%),
    radial-gradient(circle at 62% 40%,var(--crack-b) 0 1.5px,transparent 2.5px);
  animation:crack 1.1s steps(6,jump-end) forwards}
@keyframes crack{0%{opacity:0}100%{opacity:1}}
/* modals */
.modal{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center}
.modal.open{display:flex}
.card{background:var(--card);border:1px solid var(--line);border-radius:20px;padding:24px;width:min(420px,92vw);text-align:left}
.card h2{margin:0 0 10px}.card p{color:var(--mute);margin:0 0 14px}
input{width:100%;font-size:18px;letter-spacing:1px;padding:12px 14px;border-radius:14px;border:1px solid var(--line);background:var(--field);color:var(--fg);font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.row{display:flex;gap:10px;margin-top:14px}.row .btn{min-height:0;padding:12px}
.err{color:#ff8a80;margin-top:10px;min-height:1.2em}
code.tok{display:block;font-size:24px;letter-spacing:2px;background:var(--card);border:1px solid var(--line);padding:16px;border-radius:16px;margin:16px 0;word-break:break-all;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.label{color:var(--mute);font-size:13px;text-align:left;margin:0 0 6px;transition:color .6s}
.label.gold{color:var(--gold-hi)}
</style>"""

PAGE = """<!doctype html><title>Airadar plans</title>""" + STYLE + """
<body>
<main>
<h1>Airadar</h1>
<div class="grid">
  <button class="btn" id="premium">Premium<small>US$5 / month · unlimited trips & history</small></button>
  <button class="btn" id="buyout">Premium, once<small>US$50 once · yours for good, no subscription</small></button>
  <button class="btn" id="share">Share<small>US$0.99 / month · send trips to friends</small></button>
  <button class="btn forgot-btn" id="forgot">Forgot token<small>Find it with your order number</small></button>
</div>
</main>

<form id="checkout" method="post" action="/pay/checkout" hidden><input type="hidden" name="plan" id="plan"></form>

<div class="modal" id="forgotModal"><div class="card">
  <p class="label" id="fLabel">Order number</p>
  <p style="color:var(--mute);font-size:12px;margin:0 0 8px">A new token is issued; the old one stops working.</p>
  <input id="fInput" placeholder="ORD-XXXXXXXX" autocomplete="off">
  <div class="err" id="fErr"></div>
  <div class="row"><button class="btn" id="fCancel" type="button">Close</button><button class="btn" id="fGo" type="button">Find</button></div>
</div></div>

<script>
const $ = s => document.querySelector(s);
const prem = $('#premium'), buy = $('#buyout'), share = $('#share'), forgot = $('#forgot');
const all = [prem, buy, share, forgot];
function clear(){ all.forEach(b => b.classList.remove('stone','hot')); document.body.classList.remove('forgot'); }

[prem, buy, share].forEach(b => b.addEventListener('mouseenter', clear));
// Forgot: the page reddens and the other three turn to cracked stone.
forgot.addEventListener('mouseenter', () => { clear(); forgot.classList.add('hot'); document.body.classList.add('forgot'); [prem, buy, share].forEach(b => b.classList.add('stone')); });
all.forEach(b => b.addEventListener('mouseleave', clear));

prem.addEventListener('click', () => { $('#plan').value = 'premium'; $('#checkout').submit(); });
buy.addEventListener('click', () => { $('#plan').value = 'premium_buyout'; $('#checkout').submit(); });
share.addEventListener('click', () => { $('#plan').value = 'share'; $('#checkout').submit(); });

// Forgot: one box. The order number goes in; the token takes its place piece by piece
// while the label above fades from "Order number" to "Token" — about three seconds in all.
forgot.addEventListener('click', () => { $('#forgotModal').classList.add('open'); $('#fInput').focus(); });
$('#fCancel').addEventListener('click', () => { $('#forgotModal').classList.remove('open'); $('#fLabel').textContent='Order number'; $('#fLabel').classList.remove('gold'); $('#fInput').value=''; $('#fInput').readOnly=false; });
$('#fGo').addEventListener('click', async () => {
  const order = $('#fInput').value.trim().toUpperCase(); $('#fErr').textContent = '';
  const r = await fetch('/pay/api/lookup', {method:'POST', body: new URLSearchParams({order})});
  const d = await r.json();
  if (!r.ok) { $('#fErr').textContent = d.detail || 'Not found.'; return; }
  const input = $('#fInput'); input.readOnly = true;
  const from = order, to = d.token, steps = 24, ms = 3000 / steps;
  const glyphs = '0123456789abcdef';
  let i = 0;
  const tick = setInterval(() => {
    i++;
    const settled = Math.round(to.length * i / steps);
    let s = '';
    for (let k = 0; k < to.length; k++) {
      if (k < settled) s += to[k];
      else if (to[k] === '-') s += '-';
      else if (k < from.length && i < steps / 3) s += from[k];
      else s += glyphs[Math.floor(Math.random() * glyphs.length)];
    }
    input.value = s;
    if (i === Math.floor(steps / 2)) { $('#fLabel').textContent = 'Token'; $('#fLabel').classList.add('gold'); }
    if (i >= steps) { clearInterval(tick); input.value = to; $('#fErr').style.color = '#9aa3b2'; $('#fErr').textContent = d.active ? `${d.plan} · active` : `${d.plan} · not active`; }
  }, ms);
});
</script></body>"""

SUCCESS = """<!doctype html><title>Your Airadar token</title>""" + STYLE + """
<body><main>
<h1>Thank you</h1><p class="sub">{{PLAN}} · order <b>{{ORDER}}</b></p>
<p class="label" style="text-align:center">Your token — enter it in the app under Settings › Account</p>
<code class="tok" id="t">{{TOKEN}}</code>
<button class="btn" onclick="navigator.clipboard.writeText(document.getElementById('t').textContent).then(()=>this.firstChild.textContent='Copied')">Copy token</button>
<p class="sub" style="margin-top:18px">Keep the order number: it finds this token again on the plans page. The token works on the phone it is first used on, with the first Google account signed in there.</p>
</main></body>"""
