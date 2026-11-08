# syntax=docker/dockerfile:1
# MCP logs and metrics server (HTTP + SSE transport). No credentials: the
# data is simulated and no DB or AI keys are needed.
# Build context: services/mcp-servers/logs_server
#   docker build -t autoops-mcp-logs services/mcp-servers/logs_server
#   docker run --rm -p 5001:5001 -e MCP_LOGS_PORT=5001 autoops-mcp-logs

# ── Stage 1: dependencies ───────────────────────────────────────
FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Dependencies before the code: the layer stays cached while they do not change.
COPY requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt

# Packaging tools are not needed at runtime. setuptools vendors jaraco.context and wheel, which Trivy flags
# (CVE-2026-23949, CVE-2026-24049): removing them from the venv keeps them out of the runtime image.
RUN pip uninstall -y pip setuptools wheel

# ── Stage 2: minimal runtime ─────────────────────────────────────
FROM python:3.11-slim AS runtime

# Pulls in the Debian zlib1g security fix (CVE-2026-76844, CVE-2026-85091) until the python:3.11-slim base
# ships it. Remove this step once the base already includes zlib1g 1:1.3.dfsg+really1.3.1-1+deb13u1 or later.
RUN apt-get update \
    && apt-get install -y --no-install-recommends --only-upgrade zlib1g \
    && rm -rf /var/lib/apt/lists/*

# The base image also ships pip and setuptools (which vendors jaraco.context and wheel: CVE-2026-23949,
# CVE-2026-24049) in the system Python. Nothing installs packages at runtime, so remove them from this stage.
RUN pip uninstall -y pip setuptools wheel

RUN groupadd --system --gid 10001 autoops \
    && useradd --system --uid 10001 --gid autoops --no-create-home \
        --shell /usr/sbin/nologin autoops

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=autoops:autoops server.py ./server.py

# 0.0.0.0 to be reachable from other containers; isolation comes from the
# network (not published to the host). The port (MCP_LOGS_PORT) is mandatory and
# injected at runtime. No bytecode or disk writes: suitable for --read-only.
ENV PATH="/opt/venv/bin:$PATH" \
    MCP_LOGS_HOST=0.0.0.0 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 10001:10001

CMD ["python", "server.py"]
