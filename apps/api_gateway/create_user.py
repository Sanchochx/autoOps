"""Interactive creation of a dashboard user.

Run it through ``scripts/ops/create_user.sh``. The username and the password are typed at a prompt
(no echo for the password): they are never read from the environment, a file or the command line.
"""

import asyncio
import getpass
import re
import sys

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from apps.api_gateway.database import get_session_factory
from apps.api_gateway.models import User
from apps.api_gateway.security import hash_password

USERNAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{2,63}$")
MIN_PASSWORD_LENGTH = 12
MAX_PASSWORD_LENGTH = 256


class InvalidInputError(ValueError):
    """The username or the password does not meet the rules."""


def validate_credentials(username: str, password: str) -> None:
    """Raise ``InvalidInputError`` when the credentials are not acceptable."""
    if not USERNAME_PATTERN.fullmatch(username):
        raise InvalidInputError(
            "The username must be 3-64 characters: lowercase letters, digits, '.', '_' or '-'."
        )
    if not MIN_PASSWORD_LENGTH <= len(password) <= MAX_PASSWORD_LENGTH:
        raise InvalidInputError(
            f"The password must have between {MIN_PASSWORD_LENGTH} and {MAX_PASSWORD_LENGTH} characters."
        )


async def upsert_user(session: AsyncSession, username: str, password: str) -> bool:
    """Create the user or replace its password and re-enable it; ``True`` when it was created."""
    existing = (
        await session.execute(select(User).where(User.username == username))
    ).scalar_one_or_none()
    password_hash = hash_password(password)
    if existing is None:
        session.add(User(username=username, password_hash=password_hash))
    else:
        existing.password_hash = password_hash
        existing.is_active = True
    await session.commit()
    return existing is None


async def _store(username: str, password: str) -> str:
    """Create or update the user inside one event loop (the engine is bound to it)."""
    async with get_session_factory()() as session:
        found = await session.execute(select(User.id).where(User.username == username))
        if found.first() is not None:
            answer = input(f"User '{username}' exists. Replace its password? [y/N] ")
            if answer.strip().lower() != "y":
                return "unchanged"
        return "created" if await upsert_user(session, username, password) else "updated"


def main() -> int:
    """Prompt for the credentials and store the user; exit code 0 on success."""
    if not sys.stdin.isatty():
        print("create_user: an interactive terminal is required.", file=sys.stderr)
        return 2
    username = input("Username: ").strip().lower()
    password = getpass.getpass("Password: ")
    try:
        validate_credentials(username, password)
        if password != getpass.getpass("Repeat the password: "):
            raise InvalidInputError("The passwords do not match.")
    except InvalidInputError as error:
        print(f"create_user: {error}", file=sys.stderr)
        return 1
    outcome = asyncio.run(_store(username, password))
    print("Nothing changed." if outcome == "unchanged" else f"User '{username}' {outcome}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
