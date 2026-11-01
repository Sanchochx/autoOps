"""MCP server for log and metrics inspection (simulated data).

Exposes read-only tools for the Investigator Agent. It does not access the
real infrastructure: all data is simulated in this version.

Transport: HTTP with SSE (Server-Sent Events), reachable over the network from
other containers. The SSE endpoint is at `/sse` and client messages are
posted to `/messages/`. Host and port are read from the environment
(MCP_LOGS_HOST, MCP_LOGS_PORT); logs are emitted to stderr.
"""

import logging
import os
import sys

from mcp.server.fastmcp import FastMCP

logging.basicConfig(stream=sys.stderr, level=logging.INFO)
logger = logging.getLogger("logs_server")

mcp = FastMCP("autoops-logs-server")


def _configure_network() -> None:
    """Apply the listen host and port from the environment (no embedded values)."""
    port = os.environ.get("MCP_LOGS_PORT")
    if not port:
        raise RuntimeError("The MCP_LOGS_PORT environment variable is missing")
    # Loopback only by default; in a container MCP_LOGS_HOST=0.0.0.0 is set.
    mcp.settings.host = os.environ.get("MCP_LOGS_HOST", "127.0.0.1")
    mcp.settings.port = int(port)

# Simulated templates (level, message) per known service.
SIMULATED_LOGS: dict[str, list[tuple[str, str]]] = {
    "api_gateway": [
        ("INFO", "GET /health 200 3ms"),
        ("INFO", "POST /api/v1/tickets 201 18ms"),
        ("WARNING", "High latency on /api/v1/tickets: 850ms"),
        ("ERROR", "WebSocket /ws/stream: connection closed abruptly"),
        ("ERROR", "Timeout contacting the AI engine after 30s"),
    ],
    "database": [
        ("INFO", "checkpoint complete: 1204 buffers written"),
        ("WARNING", "active connections at 85% of the maximum"),
        ("ERROR", "deadlock detected between transactions 4821 and 4825"),
        ("ERROR", "slow query (12.4s): SELECT * FROM tickets WHERE status = 'open'"),
        ("INFO", "autovacuum run on the tickets table"),
    ],
}


@mcp.tool()
def get_system_logs(service_name: str) -> list[str]:
    """Return the 5 most recent (simulated) log lines of a service.

    Args:
        service_name: Service name, e.g. "api_gateway" o "database".
    """
    entries = SIMULATED_LOGS.get(service_name)
    if entries is None:
        known = ", ".join(sorted(SIMULATED_LOGS))
        raise ValueError(f"Servicio desconocido: {service_name!r}. Disponibles: {known}")
    logger.info("get_system_logs service_name=%s", service_name)
    return [f"[{level}] {service_name}: {message}" for level, message in entries]


@mcp.tool()
def get_db_metrics() -> dict[str, int | float]:
    """Return simulated database health metrics."""
    logger.info("get_db_metrics")
    return {
        "active_connections": 42,
        "max_connections": 100,
        "cpu_usage_percent": 63.5,
        "slow_transactions": 3,
    }


if __name__ == "__main__":
    _configure_network()
    logger.info("Escuchando SSE en %s:%s", mcp.settings.host, mcp.settings.port)
    mcp.run(transport="sse")
