"""API Gateway configuration (Twelve-Factor).

All parameters are read from environment variables; there are no origins,
hosts or ports hardcoded beyond the safe development fallbacks.
"""

import os


def get_cors_allowed_origins() -> list[str]:
    """Return the allowed CORS origins from ``CORS_ALLOWED_ORIGINS``.

    The value is a comma-separated list. If the variable is undefined or
    empty, returns an empty list (restrictive policy: no origin allowed;
    ``*`` is never used).
    """
    raw_origins = os.getenv("CORS_ALLOWED_ORIGINS", "")
    return [origin.strip() for origin in raw_origins.split(",") if origin.strip()]


def load_dotenv(path: str = ".env") -> None:
    """Load ``KEY=value`` pairs from a ``.env`` file into ``os.environ``.

    Does not overwrite variables already defined in the real environment. If
    the file does not exist, does nothing.
    """
    try:
        with open(path, encoding="utf-8") as env_file:
            lines = env_file.read().splitlines()
    except FileNotFoundError:
        return
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip("\"'"))


# --- Authentication (JWT) -------------------------------------------------------------------------

MIN_JWT_SECRET_LENGTH = 32
DEFAULT_JWT_TTL_MINUTES = 60
DEFAULT_LOGIN_MAX_ATTEMPTS = 5
DEFAULT_LOGIN_WINDOW_SECONDS = 300
DEFAULT_WS_AUTH_TIMEOUT_SECONDS = 5.0


def get_jwt_secret() -> str:
    """Return ``JWT_SECRET``; there is no default, so a missing or weak secret is a startup error."""
    secret = os.getenv("JWT_SECRET", "")
    if len(secret) < MIN_JWT_SECRET_LENGTH:
        raise RuntimeError(
            f"JWT_SECRET must be set to at least {MIN_JWT_SECRET_LENGTH} characters "
            "(e.g. openssl rand -hex 32)."
        )
    return secret


def _positive_number(name: str, default: float) -> float:
    """Read a positive number from the environment; an unset or invalid value falls back to ``default``."""
    try:
        value = float(os.getenv(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


def get_jwt_ttl_minutes() -> float:
    """Access token lifetime in minutes (``JWT_TTL_MINUTES``, default 60)."""
    return _positive_number("JWT_TTL_MINUTES", DEFAULT_JWT_TTL_MINUTES)


def get_login_max_attempts() -> int:
    """Failed logins allowed per client IP inside the window (``LOGIN_MAX_ATTEMPTS``)."""
    return int(_positive_number("LOGIN_MAX_ATTEMPTS", DEFAULT_LOGIN_MAX_ATTEMPTS))


def get_login_window_seconds() -> float:
    """Length of the failed-login window (``LOGIN_WINDOW_SECONDS``)."""
    return _positive_number("LOGIN_WINDOW_SECONDS", DEFAULT_LOGIN_WINDOW_SECONDS)


def get_ws_auth_timeout_seconds() -> float:
    """Time a WebSocket has to send its auth message (``WS_AUTH_TIMEOUT_SECONDS``)."""
    return _positive_number("WS_AUTH_TIMEOUT_SECONDS", DEFAULT_WS_AUTH_TIMEOUT_SECONDS)
