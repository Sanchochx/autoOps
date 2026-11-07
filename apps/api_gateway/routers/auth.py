"""Login endpoint."""

import asyncio

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from apps.api_gateway.database import get_db_session
from apps.api_gateway.models import User
from apps.api_gateway.rate_limit import FailureLimiter, get_login_limiter
from apps.api_gateway.schemas import LoginRequest, TokenResponse
from apps.api_gateway.security import create_access_token, verify_password

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])

# One message for an unknown user, a wrong password and a disabled account.
INVALID_CREDENTIALS = "Invalid username or password"


def client_key(request: Request) -> str:
    """Client IP as seen by the app (the real one behind Traefik, see --proxy-headers)."""
    return request.client.host if request.client else "unknown"


@router.post("/login", response_model=TokenResponse)
async def login(
    payload: LoginRequest,
    request: Request,
    session: AsyncSession = Depends(get_db_session),
    limiter: FailureLimiter = Depends(get_login_limiter),
) -> TokenResponse:
    """Exchange credentials for a short-lived access token.

    Failed attempts are limited per client IP (429 + ``Retry-After``). The response never says
    whether the username or the password was wrong.
    """
    key = client_key(request)
    retry_after = limiter.retry_after(key)
    if retry_after:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many failed attempts. Try again later.",
            headers={"Retry-After": str(retry_after)},
        )

    username = payload.username.strip().lower()
    user = (
        await session.execute(select(User).where(User.username == username))
    ).scalar_one_or_none()
    # argon2 is CPU-bound: keep it off the event loop. A missing user verifies a dummy hash.
    password_ok = await asyncio.to_thread(
        verify_password, payload.password, user.password_hash if user else None
    )
    if user is None or not user.is_active or not password_ok:
        limiter.record_failure(key)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=INVALID_CREDENTIALS,
            headers={"WWW-Authenticate": "Bearer"},
        )

    limiter.reset(key)
    token, lifetime = create_access_token(user.id)
    return TokenResponse(access_token=token, expires_in=lifetime)
