"""MongoDB via motor. One client for the process; indexes ensured at startup."""

import os

from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase

REFRESH_TOKEN_DAYS = 60
TRASH_RETENTION_DAYS = 30

# The colours a traveller can be; no black, white or grey, so a name in one of
# these always reads as "someone".
PALETTE = [
    "#E53935", "#F4511E", "#FB8C00", "#F9A825", "#7CB342", "#43A047",
    "#00897B", "#00ACC1", "#1E88E5", "#3949AB", "#8E24AA", "#D81B60",
]

_client: AsyncIOMotorClient | None = None


def connect() -> AsyncIOMotorDatabase:
    global _client
    # tz_aware: datetimes come back as UTC-aware, so they compare with datetime.now(timezone.utc).
    _client = AsyncIOMotorClient(os.environ.get("MONGO_URL", "mongodb://mongo:27017"), tz_aware=True)
    return _client[os.environ.get("MONGO_DB", "airadar")]


def close() -> None:
    if _client is not None:
        _client.close()


async def ensure_indexes(db: AsyncIOMotorDatabase) -> None:
    await db.users.create_index("googleSub", unique=True)
    await db.users.create_index("email")

    # A session dies on its own when its refresh token would have expired anyway.
    await db.sessions.create_index("tokenHash", unique=True)
    await db.sessions.create_index("userId")
    await db.sessions.create_index("expiresAt", expireAfterSeconds=0)

    await db.trips.create_index([("userId", 1), ("deletedAt", 1)])
    # The recycle bin empties itself: Mongo drops the document once deletedAt is
    # this old. Live trips have no deletedAt and are never touched.
    await db.trips.create_index(
        "deletedAt", expireAfterSeconds=TRASH_RETENTION_DAYS * 24 * 3600
    )

    await db.friendships.create_index("a")
    await db.friendships.create_index("b")

    await db.shares.create_index([("tripKey", 1), ("toUserId", 1)])
    await db.shares.create_index("toUserId")
    await db.shares.create_index("ownerId")
    await db.shares.create_index("token", sparse=True)

    # Answers from the history service; forgotten after CACHE_DAYS.
    await db.flightCache.create_index("cachedAt", expireAfterSeconds=90 * 24 * 3600)
