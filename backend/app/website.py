"""
The public website: the landing page at /, and the Android download.

Android installs come from here rather than an app store: the stores in mainland
China don't carry Airadar, so the APK is served straight from this server
(nothing hosted abroad to be slow or blocked). The latest build sits in
DOWNLOADS_DIR as `Airadar.apk`, with `android.json` beside it describing it —
both written by scripts/publish-apk.sh. The App Store button follows
APP_STORE_URL and reads "coming soon" until that's set.
"""
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse

router = APIRouter()

SITE = Path(__file__).parent / "site"
DOWNLOADS = Path(os.environ.get("DOWNLOADS_DIR", "/srv/downloads"))


def _android() -> dict | None:
    """The published APK's details, or None when there isn't one yet."""
    apk = DOWNLOADS / "Airadar.apk"
    if not apk.is_file():
        return None
    try:
        meta = json.loads((DOWNLOADS / "android.json").read_text())
    except (OSError, ValueError):
        meta = {}
    stat = apk.stat()
    return {
        "version": meta.get("version") or "",
        "size": stat.st_size,
        "date": meta.get("date") or datetime.fromtimestamp(stat.st_mtime, timezone.utc).date().isoformat(),
        "sha256": meta.get("sha256") or "",
    }


def _language(request: Request) -> str:
    """Chinese unless the browser asks for something else first."""
    accept = request.headers.get("accept-language", "").lower()
    first = accept.split(",")[0].strip()
    return "en" if first and not first.startswith("zh") else "zh"


@router.get("/", response_class=HTMLResponse, include_in_schema=False)
async def home(request: Request):
    page = (SITE / "index.html").read_text(encoding="utf-8")
    android = _android()
    config = {
        "appStore": os.environ.get("APP_STORE_URL", "").strip(),
        "android": android,
    }
    lang = _language(request)
    page = page.replace("__LANG__", "zh-Hans" if lang == "zh" else "en")
    page = page.replace("__CONFIG__", json.dumps(config).replace("</", "<\\/"))
    return HTMLResponse(page, headers={"Cache-Control": "no-cache"})


@router.api_route("/download/android", methods=["GET", "HEAD"], include_in_schema=False)
async def download_android():
    android = _android()
    if android is None:
        raise HTTPException(404, "No Android build has been published yet.")
    name = f"Airadar-{android['version']}.apk" if android["version"] else "Airadar.apk"
    return FileResponse(DOWNLOADS / "Airadar.apk", media_type="application/vnd.android.package-archive",
                        filename=name, headers={"Cache-Control": "no-cache"})


@router.get("/download/android.json", include_in_schema=False)
async def android_info():
    return _android() or {}


@router.get("/icon.png", include_in_schema=False)
async def icon():
    return FileResponse(SITE / "icon.png", media_type="image/png", headers={"Cache-Control": "public, max-age=86400"})


@router.get("/favicon.ico", include_in_schema=False)
async def favicon():
    return FileResponse(SITE / "icon-64.png", media_type="image/png", headers={"Cache-Control": "public, max-age=86400"})
