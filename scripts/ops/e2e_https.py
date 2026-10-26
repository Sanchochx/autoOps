#!/usr/bin/env python3
"""End-to-end check through the proxy (US-PROXY-002 AC-5): redirect, https ticket, wss events.

    venv/bin/python scripts/ops/e2e_https.py --ca tls/ca/ca.crt

Reads DOMAIN and PROXY_HTTPS_PORT/PROXY_HTTP_PORT from the environment, falling back to .env.
When DOMAIN is not resolvable on this machine, set E2E_CONNECT_ADDR=127.0.0.1 (the equivalent of
curl --resolve). Needs the `websockets` package (installed with uvicorn[standard]).
Exit 0 = every step passed, 1 = a step failed.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import socket
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parents[2]
EVENT_TIMEOUT_SECONDS = 60.0


def env_value(name: str, default: str = "") -> str:
    """Process environment first, then ROOT/.env (same precedence as docker compose)."""
    if os.environ.get(name):
        return os.environ[name]
    try:
        for line in (ROOT / ".env").read_text().splitlines():
            if line.startswith(f"{name}="):
                return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return default


def pin_address(domain: str, addr: str) -> None:
    """Resolve `domain` to `addr` for this process (like curl --resolve); TLS still checks `domain`."""
    real = socket.getaddrinfo

    def patched(host, *args, **kwargs):  # type: ignore[no-untyped-def]
        return real(addr if host == domain else host, *args, **kwargs)

    socket.getaddrinfo = patched  # type: ignore[assignment]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # type: ignore[no-untyped-def]
        return None


def step(ok: bool, label: str) -> None:
    print(f"{'OK  ' if ok else 'FAIL'} {label}")
    if not ok:
        sys.exit(1)


def check_redirect(domain: str, http_port: str) -> None:
    opener = urllib.request.build_opener(NoRedirect)
    try:
        opener.open(f"http://{domain}:{http_port}/", timeout=10)
        step(False, "http:// answers a redirect (got a success status)")
    except urllib.error.HTTPError as exc:
        location = exc.headers.get("Location", "")
        step(exc.code in (301, 308) and location.startswith("https://"), f"http:// -> {exc.code} {location}")


def create_ticket(base: str, ctx: ssl.SSLContext) -> str:
    body = json.dumps({"title": "e2e https", "description": "wss check", "severity": "low"}).encode()
    req = urllib.request.Request(
        f"{base}/api/v1/tickets", body, {"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
        step(resp.status == 201, "POST /api/v1/tickets over https -> 201")
        return str(json.load(resp)["id"])


async def run(ca: str) -> None:
    domain = env_value("DOMAIN")
    https_port = env_value("PROXY_HTTPS_PORT", "443")
    http_port = env_value("PROXY_HTTP_PORT", "80")
    if not domain:
        sys.exit("DOMAIN is not set (environment or .env)")
    if os.environ.get("E2E_CONNECT_ADDR"):
        pin_address(domain, os.environ["E2E_CONNECT_ADDR"])
    ctx = ssl.create_default_context(cafile=ca)

    check_redirect(domain, http_port)
    base = f"https://{domain}:{https_port}"
    async with websockets.connect(f"wss://{domain}:{https_port}/ws/stream", ssl=ctx) as ws:
        step(await asyncio.wait_for(ws.recv(), 10) == "connected", "wss:// handshake and greeting")
        ticket_id = await asyncio.to_thread(create_ticket, base, ctx)
        deadline = asyncio.get_running_loop().time() + EVENT_TIMEOUT_SECONDS
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                step(False, f"ai_event for ticket {ticket_id} over wss:// within {EVENT_TIMEOUT_SECONDS:.0f}s")
            raw = await asyncio.wait_for(ws.recv(), remaining)
            event = json.loads(raw)
            if event.get("type") == "ai_event" and event.get("ticket_id") == ticket_id:
                step(True, f"ai_event over wss:// (node={event.get('node')})")
                return


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ca", required=True, help="path to the local CA certificate (ca.crt)")
    asyncio.run(run(parser.parse_args().ca))


if __name__ == "__main__":
    main()
