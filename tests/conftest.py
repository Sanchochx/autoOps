"""Shared fixtures: authentication environment, users, tokens and a mocked session."""

import time
from collections.abc import Iterator
from unittest.mock import AsyncMock, MagicMock
from uuid import UUID, uuid4

import jwt
import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from apps.api_gateway.database import get_db_session, get_session_factory
from apps.api_gateway.main import app
from apps.api_gateway.models import User
from apps.api_gateway.rate_limit import get_login_limiter
from apps.api_gateway.security import create_access_token, hash_password

TEST_JWT_SECRET = "test-secret-" + "x" * 40
PASSWORD = "correct horse battery"


@pytest.fixture(autouse=True)
def auth_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """A JWT secret for every test, default limits, and a fresh login limiter."""
    monkeypatch.setenv("JWT_SECRET", TEST_JWT_SECRET)
    for name in ("JWT_TTL_MINUTES", "LOGIN_MAX_ATTEMPTS", "LOGIN_WINDOW_SECONDS", "WS_AUTH_TIMEOUT_SECONDS"):
        monkeypatch.delenv(name, raising=False)
    get_login_limiter.cache_clear()
    yield
    get_login_limiter.cache_clear()
    app.dependency_overrides.clear()


@pytest.fixture
def user() -> User:
    return User(id=uuid4(), username="admin", password_hash=hash_password(PASSWORD), is_active=True)


@pytest.fixture
def token(user: User) -> str:
    return create_access_token(user.id)[0]


def make_token(user_id: UUID, *, expires_in: int = 3600, secret: str = TEST_JWT_SECRET) -> str:
    """Token with a chosen lifetime (negative = already expired) and signing secret."""
    now = int(time.time())
    return jwt.encode({"sub": str(user_id), "iat": now, "exp": now + expires_in}, secret, algorithm="HS256")


@pytest.fixture
def auth_session(user: User) -> AsyncMock:
    """Session that knows ``user`` (by id and by username) and is injected as the DB dependency."""
    session = AsyncMock(spec=AsyncSession)

    async def get(model: type, key: object) -> User | None:
        return user if model is User and key == user.id else None

    session.get.side_effect = get
    result = MagicMock()
    result.scalar_one_or_none.return_value = user
    session.execute.return_value = result
    app.dependency_overrides[get_db_session] = lambda: session
    factory = MagicMock()
    factory.return_value.__aenter__ = AsyncMock(return_value=session)
    factory.return_value.__aexit__ = AsyncMock(return_value=False)
    app.dependency_overrides[get_session_factory] = lambda: factory
    return session
