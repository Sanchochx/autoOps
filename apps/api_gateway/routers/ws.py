"""Streaming WebSocket endpoint (authenticated with its first message)."""

import asyncio
import contextlib
import json
import logging
import time
from collections.abc import Callable

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from apps.api_gateway.config import get_ws_auth_timeout_seconds
from apps.api_gateway.connection_manager import manager
from apps.api_gateway.database import get_session_factory
from apps.api_gateway.models import User
from apps.api_gateway.security import InvalidTokenError, TokenClaims, decode_access_token

logger = logging.getLogger(__name__)

router = APIRouter(tags=["websocket"])

# Application close code (4000-4999): the client must sign in again and must not retry.
WS_UNAUTHORIZED = 4401
MAX_AUTH_MESSAGE_BYTES = 4096


async def _read_claims(websocket: WebSocket) -> TokenClaims | None:
    """Wait for ``{"type": "auth", "token": ...}`` and validate the token; ``None`` if it fails."""
    try:
        raw = await asyncio.wait_for(
            websocket.receive_text(), timeout=get_ws_auth_timeout_seconds()
        )
        if len(raw) > MAX_AUTH_MESSAGE_BYTES:
            return None
        message = json.loads(raw)
        if not isinstance(message, dict) or message.get("type") != "auth":
            return None
        token = message.get("token")
        return decode_access_token(token) if isinstance(token, str) else None
    except (TimeoutError, ValueError, InvalidTokenError, WebSocketDisconnect):
        return None


async def _close_at(websocket: WebSocket, expires_at: int, now: Callable[[], float]) -> None:
    """Close the socket when the token that opened it expires."""
    await asyncio.sleep(max(0.0, expires_at - now()))
    with contextlib.suppress(RuntimeError):
        await websocket.close(code=WS_UNAUTHORIZED)


@router.websocket("/ws/stream")
async def stream(
    websocket: WebSocket,
    session_factory: async_sessionmaker[AsyncSession] = Depends(get_session_factory),
) -> None:
    """Accept the connection, require an auth message first, then echo received messages.

    The token travels in the first message, never in the URL (the proxy logs URLs). The connection
    joins the broadcast list only after it authenticates, and is closed with 4401 when it does not
    (or when the token expires).
    """
    await websocket.accept()
    claims = await _read_claims(websocket)
    if claims is not None:
        async with session_factory() as session:
            user = await session.get(User, claims.user_id)
        if user is None or not user.is_active:
            claims = None
    if claims is None:
        with contextlib.suppress(RuntimeError):  # the client may already be gone
            await websocket.close(code=WS_UNAUTHORIZED)
        return

    manager.register(websocket)
    expiry = asyncio.create_task(_close_at(websocket, claims.expires_at, time.time))
    try:
        await manager.send_personal_message("connected", websocket)
        while True:
            data = await websocket.receive_text()
            await manager.send_personal_message(f"echo: {data}", websocket)
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        expiry.cancel()
        manager.disconnect(websocket)
