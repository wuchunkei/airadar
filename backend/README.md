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

## Endpoints

| Method | Path | Notes |
|---|---|---|
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
