"""Tests of authentication: protected REST endpoints, login, rate limit and proxy headers."""

from pathlib import Path
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

from apps.api_gateway.config import get_jwt_secret, get_jwt_ttl_minutes
from apps.api_gateway.main import app
from apps.api_gateway.models import User
from tests.conftest import PASSWORD, make_token

ROOT = Path(__file__).resolve().parents[1]
LOGIN = "/api/v1/auth/login"
PROXY = "172.30.0.2"


@pytest.fixture
def client(auth_session: AsyncMock) -> TestClient:
    return TestClient(app)


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def login(client: TestClient, password: str = PASSWORD, username: str = "admin") -> object:
    return client.post(LOGIN, json={"username": username, "password": password})


def set_empty_ticket_list(session: AsyncMock) -> None:
    result = MagicMock()
    result.scalars.return_value.all.return_value = []
    session.execute.return_value = result


# --- protected endpoints ------------------------------------------------------------------------


def test_tickets_without_token_returns_401(client: TestClient) -> None:
    response = client.get("/api/v1/tickets")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_tickets_with_token_returns_200(client: TestClient, auth_session: AsyncMock, token: str) -> None:
    set_empty_ticket_list(auth_session)
    response = client.get("/api/v1/tickets", headers=bearer(token))
    assert response.status_code == 200
    assert response.json() == []


def test_expired_token_returns_401(client: TestClient, user: User) -> None:
    response = client.get("/api/v1/tickets", headers=bearer(make_token(user.id, expires_in=-1)))
    assert response.status_code == 401


def test_forged_and_malformed_tokens_return_401(client: TestClient, user: User) -> None:
    forged = make_token(user.id, secret="another-secret-" + "z" * 32)
    for header in (bearer(forged), bearer("not.a.jwt"), {"Authorization": "Basic YWRtaW46eA=="}):
        assert client.get("/api/v1/tickets", headers=header).status_code == 401


def test_token_of_an_unknown_or_disabled_user_returns_401(
    client: TestClient, user: User, token: str
) -> None:
    assert client.get("/api/v1/tickets", headers=bearer(make_token(uuid4()))).status_code == 401
    user.is_active = False
    assert client.get("/api/v1/tickets", headers=bearer(token)).status_code == 401


def test_every_rest_route_is_protected_except_login_and_health(client: TestClient) -> None:
    public = {LOGIN, "/api/v1/health", "/health"}
    checked = 0
    for path, operations in app.openapi()["paths"].items():
        if path in public:
            continue
        for method in operations:
            url = path.replace("{ticket_id}", str(uuid4()))
            assert client.request(method.upper(), url).status_code == 401, f"{method} {path}"
            checked += 1
    assert checked >= 6


def test_health_endpoints_are_public(client: TestClient) -> None:
    for path in ("/health", "/api/v1/health"):
        response = client.get(path)
        assert response.status_code == 200
        assert response.json() == {"status": "ok", "service": "api_gateway"}


# --- login --------------------------------------------------------------------------------------


def test_login_returns_a_token_that_works(client: TestClient, auth_session: AsyncMock) -> None:
    response = login(client)
    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["expires_in"] == 3600
    set_empty_ticket_list(auth_session)
    assert client.get("/api/v1/tickets", headers=bearer(body["access_token"])).status_code == 200


def test_login_does_not_reveal_whether_the_user_or_the_password_failed(
    client: TestClient, auth_session: AsyncMock
) -> None:
    wrong_password = login(client, password="wrong password!!")
    auth_session.execute.return_value.scalar_one_or_none.return_value = None
    unknown_user = login(client, username="nobody")
    assert wrong_password.status_code == unknown_user.status_code == 401
    assert wrong_password.json() == unknown_user.json() == {"detail": "Invalid username or password"}


def test_login_of_a_disabled_user_looks_like_a_wrong_password(client: TestClient, user: User) -> None:
    user.is_active = False
    response = login(client)
    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid username or password"}


def test_login_rejects_oversized_input(client: TestClient) -> None:
    assert login(client, password="p" * 257).status_code == 422
    assert client.post(LOGIN, json={"username": "admin"}).status_code == 422


def test_login_is_rate_limited_per_client(client: TestClient) -> None:
    for _ in range(5):
        assert login(client, password="wrong password!!").status_code == 401
    blocked = login(client, password="wrong password!!")
    assert blocked.status_code == 429
    assert int(blocked.headers["retry-after"]) >= 1
    # Even the right password waits until the window passes.
    assert login(client).status_code == 429


def test_successful_login_resets_the_failure_counter(client: TestClient) -> None:
    for _ in range(4):
        login(client, password="wrong password!!")
    assert login(client).status_code == 200
    for _ in range(4):
        assert login(client, password="wrong password!!").status_code == 401


def test_limiter_window_expires(monkeypatch: pytest.MonkeyPatch) -> None:
    from apps.api_gateway.rate_limit import FailureLimiter

    now = [100.0]
    limiter = FailureLimiter(2, 60, clock=lambda: now[0])
    limiter.record_failure("ip")
    limiter.record_failure("ip")
    assert limiter.retry_after("ip") > 0
    now[0] += 61
    assert limiter.retry_after("ip") == 0


# --- rate limit behind the proxy ----------------------------------------------------------------


def proxied_client(peer: str) -> TestClient:
    """The app as uvicorn serves it: --proxy-headers trusting only ``PROXY``."""
    return TestClient(ProxyHeadersMiddleware(app, trusted_hosts=PROXY), client=(peer, 50000))


def fail_login(client: TestClient, forwarded_for: str) -> int:
    response = client.post(
        LOGIN,
        json={"username": "admin", "password": "wrong password!!"},
        headers={"X-Forwarded-For": forwarded_for},
    )
    return response.status_code


def test_rate_limit_uses_the_real_client_ip_behind_the_proxy(auth_session: AsyncMock) -> None:
    through_proxy = proxied_client(PROXY)
    for _ in range(5):
        assert fail_login(through_proxy, "203.0.113.7") == 401
    assert fail_login(through_proxy, "203.0.113.7") == 429
    # Another client behind the same proxy is not locked out by it.
    assert fail_login(through_proxy, "203.0.113.8") == 401


def test_forwarded_header_from_an_untrusted_peer_cannot_dodge_the_limit(auth_session: AsyncMock) -> None:
    direct = proxied_client("198.51.100.9")
    for index in range(5):
        assert fail_login(direct, f"203.0.113.{index}") == 401
    assert fail_login(direct, "203.0.113.200") == 429


def test_gateway_is_started_with_proxy_headers_limited_to_the_proxy() -> None:
    dockerfile = (ROOT / "apps/api_gateway/Dockerfile").read_text()
    assert "--proxy-headers" in dockerfile
    assert "--forwarded-allow-ips" in dockerfile and "$FORWARDED_ALLOW_IPS" in dockerfile
    compose = (ROOT / "docker-compose.yml").read_text()
    line = next(row for row in compose.splitlines() if row.strip().startswith("FORWARDED_ALLOW_IPS:"))
    assert "*" not in line, "FORWARDED_ALLOW_IPS must not default to trusting every peer"
    assert "EDGE_TRAEFIK_IP" in line


# --- configuration ------------------------------------------------------------------------------


def test_jwt_secret_has_no_default_and_must_be_long(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("JWT_SECRET")
    with pytest.raises(RuntimeError, match="JWT_SECRET"):
        get_jwt_secret()
    monkeypatch.setenv("JWT_SECRET", "short")
    with pytest.raises(RuntimeError, match="JWT_SECRET"):
        get_jwt_secret()


def test_token_lifetime_defaults_to_60_minutes_and_is_configurable(monkeypatch: pytest.MonkeyPatch) -> None:
    assert get_jwt_ttl_minutes() == 60
    monkeypatch.setenv("JWT_TTL_MINUTES", "5")
    assert get_jwt_ttl_minutes() == 5
    monkeypatch.setenv("JWT_TTL_MINUTES", "-3")
    assert get_jwt_ttl_minutes() == 60
