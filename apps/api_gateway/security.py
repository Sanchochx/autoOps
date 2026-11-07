"""Password hashing (argon2id) and access tokens (JWT, HS256)."""

import time
import uuid
from dataclasses import dataclass

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError

from apps.api_gateway.config import get_jwt_secret, get_jwt_ttl_minutes

JWT_ALGORITHM = "HS256"

_hasher = PasswordHasher()
# Verified when the user does not exist, so a failed login costs the same either way.
_DUMMY_HASH = _hasher.hash("autoops-dummy-password")


class InvalidTokenError(Exception):
    """The token is malformed, forged or expired."""


@dataclass(frozen=True)
class TokenClaims:
    """Validated claims of an access token."""

    user_id: uuid.UUID
    expires_at: int


def hash_password(password: str) -> str:
    """Return the argon2id hash of ``password`` (random salt included)."""
    return _hasher.hash(password)


def verify_password(password: str, password_hash: str | None) -> bool:
    """Check ``password`` against ``password_hash``; ``None`` verifies a dummy hash and returns False."""
    try:
        _hasher.verify(password_hash or _DUMMY_HASH, password)
    except (VerificationError, InvalidHashError):
        return False
    return password_hash is not None


def create_access_token(user_id: uuid.UUID) -> tuple[str, int]:
    """Return ``(token, lifetime in seconds)`` for ``user_id``."""
    lifetime = int(get_jwt_ttl_minutes() * 60)
    now = int(time.time())
    payload = {"sub": str(user_id), "iat": now, "exp": now + lifetime}
    return jwt.encode(payload, get_jwt_secret(), algorithm=JWT_ALGORITHM), lifetime


def decode_access_token(token: str) -> TokenClaims:
    """Validate signature and expiry; raise ``InvalidTokenError`` otherwise."""
    try:
        payload = jwt.decode(
            token,
            get_jwt_secret(),
            algorithms=[JWT_ALGORITHM],
            options={"require": ["exp", "sub"]},
        )
        return TokenClaims(user_id=uuid.UUID(payload["sub"]), expires_at=int(payload["exp"]))
    except (jwt.PyJWTError, ValueError, TypeError) as error:
        raise InvalidTokenError("Invalid or expired token") from error
