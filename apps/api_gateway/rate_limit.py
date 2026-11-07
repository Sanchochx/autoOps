"""In-memory limiter of failed logins per client key.

Per-process state: valid while the gateway runs as a single uvicorn worker in a single container (the
current deployment). Several replicas would each keep their own counter and need a shared store.
"""

import time
from collections import deque
from collections.abc import Callable
from functools import lru_cache

from apps.api_gateway.config import get_login_max_attempts, get_login_window_seconds

MAX_TRACKED_KEYS = 10_000


class FailureLimiter:
    """Allow ``max_failures`` failures per key inside a sliding ``window_seconds`` window."""

    def __init__(
        self,
        max_failures: int,
        window_seconds: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._max = max_failures
        self._window = window_seconds
        self._clock = clock
        self._failures: dict[str, deque[float]] = {}

    def _recent(self, key: str) -> deque[float]:
        failures = self._failures.get(key)
        if failures is None:
            return deque()
        cutoff = self._clock() - self._window
        while failures and failures[0] <= cutoff:
            failures.popleft()
        if not failures:
            del self._failures[key]
        return failures

    def retry_after(self, key: str) -> int:
        """Seconds until ``key`` may try again; 0 when it is not blocked."""
        failures = self._recent(key)
        if len(failures) < self._max:
            return 0
        return max(1, int(failures[0] + self._window - self._clock()) + 1)

    def record_failure(self, key: str) -> None:
        """Count one failed attempt for ``key``."""
        if key not in self._failures and len(self._failures) >= MAX_TRACKED_KEYS:
            for stale in [k for k in self._failures if not self._recent(k)]:
                self._failures.pop(stale, None)
            if len(self._failures) >= MAX_TRACKED_KEYS:
                self._failures.pop(next(iter(self._failures)))
        self._failures.setdefault(key, deque()).append(self._clock())

    def reset(self, key: str) -> None:
        """Forget the failures of ``key`` (after a successful login)."""
        self._failures.pop(key, None)


@lru_cache(maxsize=1)
def get_login_limiter() -> FailureLimiter:
    """Process-wide limiter configured from ``LOGIN_MAX_ATTEMPTS`` and ``LOGIN_WINDOW_SECONDS``."""
    return FailureLimiter(get_login_max_attempts(), get_login_window_seconds())
