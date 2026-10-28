"""CI-only guard: the backend tests must not reach the network (US-CICD-001 AC-2).

Loaded automatically by Python when this directory is on PYTHONPATH. Connections to loopback are allowed
(the tests use in-process clients); any other IP socket connection raises, so a test that quietly depends on
an LLM provider or any remote service fails here instead of passing thanks to the runner's internet access.
"""
import socket

_LOOPBACK = {"127.0.0.1", "::1", "localhost"}
_connect = socket.socket.connect


def _guarded_connect(self, address):
    host = address[0] if isinstance(address, tuple) else address
    if self.family in (socket.AF_INET, socket.AF_INET6) and host not in _LOOPBACK:
        raise OSError(f"network access blocked in CI tests: {address}")
    return _connect(self, address)


socket.socket.connect = _guarded_connect
