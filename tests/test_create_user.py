"""Tests of the interactive user creation (credentials come from prompts only)."""

import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from apps.api_gateway import create_user
from apps.api_gateway.models import User
from apps.api_gateway.security import verify_password


@pytest.mark.parametrize("username", ["", "ab", "Admin", "has space", "-x-", "a" * 65])
def test_invalid_usernames_are_rejected(username: str) -> None:
    with pytest.raises(create_user.InvalidInputError):
        create_user.validate_credentials(username, "a long enough password")


def test_short_password_is_rejected() -> None:
    with pytest.raises(create_user.InvalidInputError):
        create_user.validate_credentials("admin", "short")


def test_upsert_creates_a_hashed_user() -> None:
    session = AsyncMock(spec=AsyncSession)
    result = MagicMock()
    result.scalar_one_or_none.return_value = None
    session.execute.return_value = result
    session.add = MagicMock()
    assert asyncio.run(create_user.upsert_user(session, "admin", "a long enough password")) is True
    stored: User = session.add.call_args.args[0]
    assert stored.password_hash != "a long enough password"
    assert verify_password("a long enough password", stored.password_hash)


def test_upsert_replaces_the_password_and_reenables_the_user() -> None:
    existing = User(username="admin", password_hash="old", is_active=False)
    session = AsyncMock(spec=AsyncSession)
    result = MagicMock()
    result.scalar_one_or_none.return_value = existing
    session.execute.return_value = result
    assert asyncio.run(create_user.upsert_user(session, "admin", "a long enough password")) is False
    assert existing.is_active is True
    assert verify_password("a long enough password", existing.password_hash)


def test_main_refuses_to_run_without_a_terminal(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.setattr("sys.stdin", MagicMock(isatty=lambda: False))
    assert create_user.main() == 2
    assert "interactive terminal" in capsys.readouterr().err
