# Airadar backend

Two containers: the API in front of AirLabs, and MongoDB for accounts and trips.
Every API key lives here, never in the APK.

## Deploy on the server (first time)

```bash
# 1. Docker + compose plugin (Debian/Ubuntu). Skip if you already have it.
curl -fsSL https://get.docker.com | sh

# 2. Get the code
git clone https://github.com/wuchunkei/airadar.git
cd airadar/backend

# 3. Secrets — AIRLABS_API_KEY, APP_TOKEN, GOOGLE_CLIENT_ID (the Web client), JWT_SECRET
cp .env.example .env
nano .env

# 4. Build and start
docker compose up -d --build

# 5. Check
curl http://127.0.0.1:8080/health
curl -H "X-Airadar-Token: <your APP_TOKEN>" "http://127.0.0.1:8080/flights/CX888/$(date -d tomorrow +%F)"
```

## Update later

```bash
cd airadar && git pull && cd backend && docker compose up -d --build
```

## Website and the Android download

`/` is the public website; `/download/android` serves the latest APK (Chinese
app stores don't carry Airadar, so Android users install from here). To publish
a new Android build, on the Mac:

```bash
./scripts/publish-apk.sh                      # signed release build → backend/downloads/
scp backend/downloads/* SERVER:airadar/backend/downloads/
```

The container mounts `backend/downloads/` read-only; the site shows the new
version at once, no restart needed. Set `APP_STORE_URL` in `.env` (then
`docker compose up -d`) to turn on the App Store button.

## Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/` | the website |
| GET | `/download/android` | latest APK; `/download/android.json` describes it |
| GET | `/health` | no auth |
| GET | `/flights/{IATA}/{YYYY-MM-DD}` | `X-Airadar-Token` header |
| GET | `/airports/{IATA}` | `X-Airadar-Token` header |
| POST | `/auth/google` | `{idToken}` from the phone's Google sign-in → access + refresh tokens |
| POST | `/auth/refresh` | `{refreshToken}` → new pair (old one is spent) |
| POST | `/auth/logout` | `{refreshToken}` |
| GET | `/auth/me` | `Authorization: Bearer <access>` |
| GET | `/trips`, `/trips/deleted` | Bearer |
| PUT | `/trips/{id}` | Bearer; upsert |
| DELETE | `/trips/{id}` | Bearer; to the recycle bin (30 days) |
| POST | `/trips/{id}/restore` | Bearer |

## HTTPS

Links people share should be `https://`, and that needs a domain name — a
certificate cannot be issued for a bare IP. Once a domain's A record points at
this server:

```bash
# in .env
DOMAIN=airadar.example.com
PUBLIC_URL=https://airadar.example.com
ANDROID_SHA256_CERTS=AA:BB:...   # from Android Studio > Gradle > signingReport

docker compose --profile https up -d
```

Caddy takes ports 80/443, fetches a Let's Encrypt certificate and forwards to
the API. Then set `backend.url=https://airadar.example.com` and
`link.host=airadar.example.com` in the app's `local.properties`, and Android
opens shared links straight in the app.

Without a domain the API stays on plain HTTP :8080 and links use the IP.

## Plans (Stripe)

Plans are sold on `https://<PUBLIC_URL>/pay`; the buyer gets a token to paste
into the app (Settings › Plan). In the Stripe dashboard:

1. Products → two recurring prices, US$1/month and US$5/month → copy their
   `price_...` ids into `STRIPE_PRICE_SUPERIOR` / `STRIPE_PRICE_PREMIUM`.
2. Developers → API keys → `STRIPE_SECRET_KEY`.
3. Developers → Webhooks → add `https://<PUBLIC_URL>/billing/stripe/webhook`
   with events `checkout.session.completed`, `customer.subscription.updated`,
   `customer.subscription.deleted`, `invoice.paid`, `invoice.payment_failed`
   → copy the signing secret into `STRIPE_WEBHOOK_SECRET`.

In the app the token comes first (Settings › Account): it is bound to that
phone, then to the first Google account signed in with it, and is refused
elsewhere. It stays valid while Stripe reports the subscription paid, plus
three days of grace. "Forgot token" on the plans page finds it by order
number; "Upgrade to Premium" keeps the token and credits the unused part of
the Superior month.
