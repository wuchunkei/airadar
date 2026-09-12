# Airadar history service

Runs on the WARP-exit machine, apart from the main backend. Asks
Flightradar24's web endpoints for a flight number's past flights.

```bash
git clone https://github.com/wuchunkei/airadar.git && cd airadar/fr24
cp .env.example .env && nano .env      # SERVICE_TOKEN; FR24 account if you have one
docker compose up -d --build
curl -H "X-Service-Token: <token>" http://127.0.0.1:8090/history/CX888/$(date -d '3 days ago' +%F)
```

Then on the main backend's `.env`:

```
FR24_SERVICE_URL=http://<this machine's address>:8090
FR24_SERVICE_TOKEN=<the same token>
```

Reach: anonymous ≈ one week back; FR24 Gold account ≈ one year; Business ≈ three years.
