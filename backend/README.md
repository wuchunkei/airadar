# Airadar backend

One container. AirLabs answers first; Umetrip (via the vendored
[fuck-ume-trip](https://github.com/andelf/fuck-ume-trip)) is asked only when
AirLabs cannot. Every API key lives here, never in the APK.

## Deploy on the server (first time)

```bash
# 1. Docker + compose plugin (Debian/Ubuntu). Skip if you already have it.
curl -fsSL https://get.docker.com | sh

# 2. Get the code, including the vendored Umetrip client
git clone --recurse-submodules https://github.com/wuchunkei/airadar.git
cd airadar/backend

# 3. Secrets — fill AIRLABS_API_KEY and pick an APP_TOKEN
cp .env.example .env
nano .env

# 4. Build and start (compiles the Umetrip signer inside the image)
docker compose up -d --build

# 5. Check
curl http://127.0.0.1:8080/health
curl -H "X-Airadar-Token: <your APP_TOKEN>" "http://127.0.0.1:8080/probe/umetrip"
```

If `/probe/umetrip` returns 502, the 2019 protocol no longer works and only
AirLabs is live. Set `UMETRIP_ENABLED=false` in `.env` to stop trying.

## Update later

```bash
cd airadar && git pull --recurse-submodules && cd backend && docker compose up -d --build
```

## Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | no auth |
| GET | `/flights/{IATA}/{YYYY-MM-DD}` | `X-Airadar-Token` header |
| GET | `/airports/{IATA}` | `X-Airadar-Token` header |
| GET | `/probe/umetrip` | one-off fallback check |

Open port 8080 in the server firewall (or put nginx + TLS in front — recommended
before the app talks to it over the public internet).
