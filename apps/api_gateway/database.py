"""Async PostgreSQL connection (SQLAlchemy 2.x + asyncpg).

``DATABASE_URL`` is read from the environment (Twelve-Factor). The engine and
the session factory are created lazily so importing the module does not
require an available database.
"""

import os
from collections.abc import AsyncIterator
from functools import lru_cache

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    """Declarative base shared by all ORM models."""


def get_database_url() -> str:
    """Return ``DATABASE_URL`` or fail with an explicit error if it is missing."""
    url = os.getenv("DATABASE_URL", "").strip()
    if not url:
        raise RuntimeError("The DATABASE_URL environment variable is not set.")
    return url


@lru_cache(maxsize=1)
def get_engine() -> AsyncEngine:
    """Create (only once) the async engine from ``DATABASE_URL``."""
    return create_async_engine(get_database_url(), pool_pre_ping=True)


@lru_cache(maxsize=1)
def get_session_factory() -> async_sessionmaker[AsyncSession]:
    """Create (only once) the async session factory."""
    return async_sessionmaker(get_engine(), expire_on_commit=False)


async def get_db_session() -> AsyncIterator[AsyncSession]:
    """FastAPI dependency: one session per request, closed when done."""
    async with get_session_factory()() as session:
        yield session
