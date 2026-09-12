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

Open port 8080 in the server firewall (or put nginx + TLS in front — recommended
before the app talks to it over the public internet).
