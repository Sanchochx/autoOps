"""Tests of the /ws/stream WebSocket endpoint: first-message authentication (AC-3)."""

import json
import time
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from apps.api_gateway.connection_manager import manager
from apps.api_gateway.main import app
from apps.api_gateway.models import User
from tests.conftest import TEST_JWT_SECRET, make_token

client = TestClient(app)


def auth_message(token: str) -> str:
    return json.dumps({"type": "auth", "token": token})


def assert_rejected(websocket: object) -> None:
    with pytest.raises(WebSocketDisconnect) as closed:
        websocket.receive_text()  # type: ignore[attr-defined]
    assert closed.value.code == 4401


def test_connect_with_valid_token_echoes_and_disconnects(auth_session: AsyncMock, token: str) -> None:
    with client.websocket_connect("/ws/stream") as websocket:
        websocket.send_text(auth_message(token))
        assert websocket.receive_text() == "connected"
        assert len(manager.active_connections) == 1
        websocket.send_text("hola")
        assert websocket.receive_text() == "echo: hola"
    assert manager.active_connections == []


def test_no_token_is_rejected(auth_session: AsyncMock) -> None:
    with client.websocket_connect("/ws/stream") as websocket:
        websocket.send_text("hello")
        assert_rejected(websocket)
    assert manager.active_connections == []


def test_silent_client_is_rejected_after_the_timeout(
    auth_session: AsyncMock, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("WS_AUTH_TIMEOUT_SECONDS", "0.2")
    with client.websocket_connect("/ws/stream") as websocket:
        assert_rejected(websocket)


def test_token_in_the_query_string_is_not_accepted(auth_session: AsyncMock, token: str) -> None:
    with client.websocket_connect(f"/ws/stream?token={token}") as websocket:
        websocket.send_text("no auth message")
        assert_rejected(websocket)


@pytest.mark.parametrize(
    "message",
    [
        "not json",
        json.dumps(["auth"]),
        json.dumps({"type": "hello", "token": "x"}),
        json.dumps({"type": "auth"}),
        json.dumps({"type": "auth", "token": 42}),
        json.dumps({"type": "auth", "token": "garbage"}),
    ],
)
def test_malformed_auth_messages_are_rejected(auth_session: AsyncMock, message: str) -> None:
    with client.websocket_connect("/ws/stream") as websocket:
        websocket.send_text(message)
        assert_rejected(websocket)


def test_expired_token_is_rejected(auth_session: AsyncMock, user: User) -> None:
    with client.websocket_connect("/ws/stream") as websocket:
        websocket.send_text(auth_message(make_token(user.id, expires_in=-5)))
        assert_rejected(websocket)


def test_token_signed_with_another_secret_is_rejected(auth_session: AsyncMock, user: User) -> None:
    with client.websocket_connect("/ws/stream") as websocket:
        websocket.send_text(auth_message(make_token(user.id, secret="other-" + "y" * 40)))
        assert_rejected(websocket)
    assert TEST_JWT_SECRET != "other-" + "y" * 40


def test_disabled_user_is_rejected(auth_session: AsyncMock, user: User, token: str) -> None:
    user.is_active = False
    with client.websocket_connect("/ws/stream") as websocket:
        websocket.send_text(auth_message(token))
        assert_rejected(websocket)


def test_connection_is_closed_when_its_token_expires(auth_session: AsyncMock, user: User) -> None:
    short_lived = make_token(user.id, expires_in=1)
    started = time.monotonic()
    with client.websocket_connect("/ws/stream") as websocket:
        websocket.send_text(auth_message(short_lived))
        assert websocket.receive_text() == "connected"
        assert_rejected(websocket)
    assert manager.active_connections == []
    assert time.monotonic() - started < 5
