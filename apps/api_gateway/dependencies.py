"""FastAPI dependencies that authenticate requests."""

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from apps.api_gateway.database import get_db_session
from apps.api_gateway.models import User
from apps.api_gateway.security import InvalidTokenError, TokenClaims, decode_access_token

_bearer = HTTPBearer(auto_error=False)


def unauthorized(detail: str = "Not authenticated") -> HTTPException:
    """401 with the challenge header; the same shape for every authentication failure."""
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def get_token_claims(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> TokenClaims:
    """Validate the Bearer token (signature, expiry) without touching the database."""
    if credentials is None:
        raise unauthorized()
    try:
        return decode_access_token(credentials.credentials)
    except InvalidTokenError:
        raise unauthorized("Invalid or expired token") from None


async def get_current_user(
    claims: TokenClaims = Depends(get_token_claims),
    session: AsyncSession = Depends(get_db_session),
) -> User:
    """Return the active user the token belongs to, or answer 401."""
    user = await session.get(User, claims.user_id)
    if user is None or not user.is_active:
        raise unauthorized("Invalid or expired token")
    return user
