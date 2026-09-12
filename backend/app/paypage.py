"""The /pay page: four buttons, Stripe behind two of them, and the hover choreography."""

STYLE = """<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#0f1115;--fg:#eceff4;--mute:#9aa3b2;--green:#0f5a3a;--green-hi:#1fb37a;--gold:#b8860b;--gold-hi:#ffd24a;--red:#b3261e}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;display:flex;align-items:center;justify-content:center}
main{width:min(560px,92vw);text-align:center}
h1{margin:0 0 6px;font-size:28px}p.sub{color:var(--mute);margin:0 0 28px}
.grid{display:grid;gap:14px}
.btn{position:relative;display:block;width:100%;padding:18px 20px;border-radius:20px;border:2px solid #2a2f3a;background:#161a22;color:var(--fg);font-size:18px;font-weight:600;cursor:pointer;text-decoration:none;transition:border-color .2s,background .2s;overflow:hidden}
.btn small{display:block;font-weight:400;color:var(--mute);font-size:13px;margin-top:4px}
/* the frame is a separate layer so it can be masked left→right */
.btn::before{content:"";position:absolute;inset:-2px;border-radius:20px;border:2px solid transparent;pointer-events:none;
  -webkit-mask:linear-gradient(90deg,#000 var(--reveal,100%),transparent var(--reveal,100%));mask:linear-gradient(90deg,#000 var(--reveal,100%),transparent var(--reveal,100%))}
@keyframes blinkGreen{0%,100%{border-color:var(--green)}50%{border-color:var(--green-hi);box-shadow:0 0 18px rgba(31,179,122,.35)}}
@keyframes blinkGold{0%,100%{border-color:var(--gold)}50%{border-color:var(--gold-hi);box-shadow:0 0 18px rgba(255,210,74,.35)}}
.blink-green::before{animation:blinkGreen 1s steps(2,jump-none) infinite}
.blink-gold::before{animation:blinkGold 1s steps(2,jump-none) infinite}
/* upgrade: green drains left→right one quarter per second; gold fills the same way */
@keyframes drain{0%{--reveal:100%}25%{--reveal:75%}50%{--reveal:50%}75%{--reveal:25%}100%{--reveal:0%}}
@keyframes fill{0%{--reveal:0%}25%{--reveal:25%}50%{--reveal:50%}75%{--reveal:75%}100%{--reveal:100%}}
@property --reveal{syntax:"<percentage>";inherits:false;initial-value:100%}
.drain-green::before{animation:blinkGreen 1s steps(2,jump-none) infinite,drain 4s steps(4,jump-end) forwards}
.fill-gold::before{animation:blinkGold 1s steps(2,jump-none) infinite,fill 4s steps(4,jump-end) forwards}
/* forgot: the page reddens, the others turn to stone and crack */
body.forgot{background:#2a0c0c;transition:background 1.5s}
body.forgot main{transition:none}
.stone{filter:grayscale(1) brightness(.75);color:#c9c9c9;transition:filter 1.2s}
.stone::after{content:"";position:absolute;inset:0;border-radius:20px;pointer-events:none;opacity:0;
  background:
    linear-gradient(115deg,transparent 48%,rgba(0,0,0,.9) 49%,transparent 51%),
    linear-gradient(35deg,transparent 30%,rgba(0,0,0,.8) 30.6%,transparent 31.4%),
    linear-gradient(160deg,transparent 62%,rgba(0,0,0,.85) 62.5%,transparent 63.2%),
    linear-gradient(80deg,transparent 78%,rgba(0,0,0,.7) 78.4%,transparent 79%);
  animation:crack 1.2s ease-out forwards}
@keyframes crack{0%{opacity:0;transform:scale(1)}60%{opacity:1;transform:scale(1.005)}100%{opacity:1;transform:scale(1)}}
.forgot-btn.hot{border-color:var(--red);background:#3a1010;transition:border-color 1.2s,background 1.2s}
/* modal */
.modal{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center}
.modal.open{display:flex}
.card{background:#161a22;border:1px solid #2a2f3a;border-radius:20px;padding:24px;width:min(420px,92vw);text-align:left}
.card h2{margin:0 0 10px}.card p{color:var(--mute);margin:0 0 14px}
input{width:100%;font-size:18px;letter-spacing:1px;padding:12px 14px;border-radius:14px;border:1px solid #2a2f3a;background:#0f1115;color:var(--fg);font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.row{display:flex;gap:10px;margin-top:14px}.row .btn{padding:12px}
.err{color:#ff8a80;margin-top:10px;min-height:1.2em}
code.tok{display:block;font-size:24px;letter-spacing:2px;background:#161a22;padding:16px;border-radius:16px;margin:16px 0;word-break:break-all;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.label{color:var(--mute);font-size:13px;text-align:left;margin:0 0 6px;transition:color .6s}
.label.gold{color:var(--gold-hi)}
</style>"""

PAGE = """<!doctype html><title>Airadar plans</title>""" + STYLE + """
<body><main>
<h1>Airadar</h1><p class="sub">Pick a plan. You get a token to enter in the app.</p>
<div class="grid">
  <button class="btn" id="superior">Superior<small>US$1 / month · sync, friends, 5 past & 10 ahead</small></button>
  <button class="btn" id="premium">Premium<small>US$5 / month · everything, no limits</small></button>
  <button class="btn" id="upgrade">Upgrade to Premium<small>Keep your token · pay only the difference</small></button>
  <button class="btn forgot-btn" id="forgot">Forgot token<small>Find it with your order number</small></button>
</div>
</main>

<form id="checkout" method="post" action="/pay/checkout" hidden><input type="hidden" name="plan" id="plan"></form>
<form id="upgradeForm" method="post" action="/pay/upgrade" hidden><input type="hidden" name="token" id="upgradeToken"></form>

<div class="modal" id="upgradeModal"><div class="card">
  <h2>Upgrade to Premium</h2><p>Enter your Superior token. What is left of this month is credited against the first Premium month.</p>
  <input id="upTok" placeholder="AIR-XXXX-XXXX-XXXX" autocomplete="off">
  <div class="err" id="upErr"></div>
  <div class="row"><button class="btn" id="upCancel" type="button">Cancel</button><button class="btn" id="upGo" type="button">Check</button></div>
</div></div>

<div class="modal" id="forgotModal"><div class="card">
  <p class="label" id="fLabel">Order number</p>
  <input id="fInput" placeholder="ORD-XXXXXXXX" autocomplete="off">
  <div class="err" id="fErr"></div>
  <div class="row"><button class="btn" id="fCancel" type="button">Close</button><button class="btn" id="fGo" type="button">Find</button></div>
</div></div>

<script>
const $ = s => document.querySelector(s);
const sup = $('#superior'), prem = $('#premium'), up = $('#upgrade'), forgot = $('#forgot');
const all = [sup, prem, up, forgot];
function clear(){ all.forEach(b => b.classList.remove('blink-green','blink-gold','drain-green','fill-gold','stone','hot')); document.body.classList.remove('forgot'); }

// Superior: deep green, one blink a second. Premium: gold, the same.
sup.addEventListener('mouseenter', () => { clear(); sup.classList.add('blink-green'); });
prem.addEventListener('mouseenter', () => { clear(); prem.classList.add('blink-gold'); });
// Upgrade: Superior's green drains away left to right, a quarter a second; Premium's gold fills in the
// same way and, once full, keeps blinking gold on its own.
up.addEventListener('mouseenter', () => { clear(); sup.classList.add('drain-green'); prem.classList.add('fill-gold'); });
// Forgot: the page reddens and the other three turn to cracked stone.
forgot.addEventListener('mouseenter', () => { clear(); forgot.classList.add('hot'); document.body.classList.add('forgot'); [sup, prem, up].forEach(b => b.classList.add('stone')); });
all.forEach(b => b.addEventListener('mouseleave', clear));

sup.addEventListener('click', () => { $('#plan').value = 'superior'; $('#checkout').submit(); });
prem.addEventListener('click', () => { $('#plan').value = 'premium'; $('#checkout').submit(); });

// Upgrade: the token is checked first; only a live Superior token goes on to Stripe.
up.addEventListener('click', () => { $('#upgradeModal').classList.add('open'); $('#upTok').focus(); });
$('#upCancel').addEventListener('click', () => $('#upgradeModal').classList.remove('open'));
$('#upGo').addEventListener('click', async () => {
  const token = $('#upTok').value.trim().toUpperCase(); $('#upErr').textContent = '';
  const r = await fetch('/pay/api/upgrade-check', {method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify({token})});
  const d = await r.json();
  if (!r.ok) { $('#upErr').textContent = d.detail || 'Could not check the token.'; return; }
  $('#upErr').style.color = '#9aa3b2';
  $('#upErr').textContent = `First month: US$${(d.firstMonthCents/100).toFixed(2)} (US$${(d.creditCents/100).toFixed(2)} of Superior credited). Sending you to Stripe…`;
  $('#upgradeToken').value = token; setTimeout(() => $('#upgradeForm').submit(), 900);
});

// Forgot: one box. The order number goes in; the token takes its place piece by piece
// while the label above fades from "Order number" to "Token" — about three seconds in all.
forgot.addEventListener('click', () => { $('#forgotModal').classList.add('open'); $('#fInput').focus(); });
$('#fCancel').addEventListener('click', () => { $('#forgotModal').classList.remove('open'); $('#fLabel').textContent='Order number'; $('#fLabel').classList.remove('gold'); $('#fInput').value=''; $('#fInput').readOnly=false; });
$('#fGo').addEventListener('click', async () => {
  const order = $('#fInput').value.trim().toUpperCase(); $('#fErr').textContent = '';
  const r = await fetch('/pay/api/lookup?order=' + encodeURIComponent(order));
  const d = await r.json();
  if (!r.ok) { $('#fErr').textContent = d.detail || 'Not found.'; return; }
  const input = $('#fInput'); input.readOnly = true;
  const from = order, to = d.token, steps = 24, ms = 3000 / steps;
  const glyphs = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789-';
  let i = 0;
  const tick = setInterval(() => {
    i++;
    const settled = Math.round(to.length * i / steps);
    let s = '';
    for (let k = 0; k < to.length; k++) {
      if (k < settled) s += to[k];
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
