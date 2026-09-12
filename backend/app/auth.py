"""
Sign-in with Google, and the two tokens that follow.

The phone shows Google's own account picker and gets back an ID token signed by
Google. It posts that here once; from then on it talks only to this server with:

  access token   — a short-lived JWT carried on every request
  refresh token  — a long random string, kept on the phone, exchanged for a new
                   access token whenever one expires. Each exchange also rotates
                   it and pushes its expiry another REFRESH_TOKEN_DAYS out, so a
                   traveller who opens the app at all in that window never signs
                   in again.
"""

import hashlib
import os
import random
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from bson import ObjectId
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token as google_id_token
from pydantic import BaseModel

from .db import PALETTE, REFRESH_TOKEN_DAYS

ACCESS_TOKEN_MINUTES = 60

router = APIRouter(prefix="/auth", tags=["auth"])


def _jwt_secret() -> str:
    secret = os.environ.get("JWT_SECRET", "").strip()
    if not secret:
        raise HTTPException(status_code=500, detail="JWT_SECRET is not set on the server.")
    return secret


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


# ---- models ----------------------------------------------------------------


class GoogleLogin(BaseModel):
    idToken: str
    device: str | None = None


class RefreshRequest(BaseModel):
    refreshToken: str


class User(BaseModel):
    id: str
    email: str
    name: str | None = None
    avatarUrl: str | None = None


class TokenPair(BaseModel):
    accessToken: str
    refreshToken: str
    accessExpiresIn: int  # seconds
    user: User


# ---- helpers -----------------------------------------------------------------


def _user_out(doc: dict) -> User:
    return User(
        id=str(doc["_id"]),
        email=doc["email"],
        name=doc.get("name"),
        avatarUrl=doc.get("avatarUrl"),
    )


def _access_token(user_id: str) -> str:
    now = _now()
    return jwt.encode(
        {"sub": user_id, "iat": now, "exp": now + timedelta(minutes=ACCESS_TOKEN_MINUTES)},
        _jwt_secret(),
        algorithm="HS256",
    )


async def _new_session(db, user_id: ObjectId, device: str | None) -> str:
    """Creates a session row and returns the raw refresh token (only the hash is stored)."""
    raw = secrets.token_urlsafe(48)
    await db.sessions.insert_one({
        "userId": user_id,
        "tokenHash": _hash(raw),
        "device": device,
        "createdAt": _now(),
        "expiresAt": _now() + timedelta(days=REFRESH_TOKEN_DAYS),
    })
    return raw


async def _issue(db, user: dict, device: str | None) -> TokenPair:
    return TokenPair(
        accessToken=_access_token(str(user["_id"])),
        refreshToken=await _new_session(db, user["_id"], device),
        accessExpiresIn=ACCESS_TOKEN_MINUTES * 60,
        user=_user_out(user),
    )


# ---- dependency used by every signed-in route ----------------------------------


async def current_user(request: Request, authorization: str | None = Header(default=None)) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Sign in required.")
    token = authorization[7:].strip()
    try:
        claims = jwt.decode(token, _jwt_secret(), algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Access token expired.")
    except jwt.PyJWTError:
        raise HTTPException(status_code=401, detail="Bad access token.")
    user = await request.app.state.db.users.find_one({"_id": ObjectId(claims["sub"])})
    if not user:
        raise HTTPException(status_code=401, detail="Account no longer exists.")
    return user


# ---- routes ----------------------------------------------------------------------


@router.post("/google", response_model=TokenPair)
async def google_login(body: GoogleLogin, request: Request):
    client_id = os.environ.get("GOOGLE_CLIENT_ID", "").strip()
    if not client_id:
        raise HTTPException(status_code=500, detail="GOOGLE_CLIENT_ID is not set on the server.")
    try:
        info = google_id_token.verify_oauth2_token(body.idToken, google_requests.Request(), client_id)
    except ValueError as e:
        raise HTTPException(status_code=401, detail=f"Google rejected the sign-in: {e}")
    if not info.get("email_verified", False):
        raise HTTPException(status_code=401, detail="Google account email is not verified.")

    db = request.app.state.db
    now = _now()
    user = await db.users.find_one_and_update(
        {"googleSub": info["sub"]},
        {
            "$set": {
                "email": info["email"].lower(),
                "name": info.get("name"),
                "avatarUrl": info.get("picture"),
                "lastLoginAt": now,
            },
            # A colour is dealt at sign-up; the traveller can change it in Settings.
            "$setOnInsert": {
                "createdAt": now,
                "settings": {},
                "givenName": info.get("given_name"),
                "color": random.choice(PALETTE),
                "findableByEmail": False,
            },
        },
        upsert=True,
        return_document=True,
    )
    return await _issue(db, user, body.device)


@router.post("/refresh", response_model=TokenPair)
async def refresh(body: RefreshRequest, request: Request):
    db = request.app.state.db
    # Rotation: the old token is spent the moment it is presented, whatever happens next.
    session = await db.sessions.find_one_and_delete({"tokenHash": _hash(body.refreshToken)})
    if not session or session["expiresAt"] < _now():
        raise HTTPException(status_code=401, detail="Session expired; sign in again.")
    user = await db.users.find_one({"_id": session["userId"]})
    if not user:
        raise HTTPException(status_code=401, detail="Account no longer exists.")
    return await _issue(db, user, session.get("device"))


@router.post("/logout", status_code=204)
async def logout(body: RefreshRequest, request: Request):
    await request.app.state.db.sessions.delete_one({"tokenHash": _hash(body.refreshToken)})


@router.get("/me", response_model=User)
async def me(user: dict = Depends(current_user)):
    return _user_out(user)
