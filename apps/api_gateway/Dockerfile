# syntax=docker/dockerfile:1
# API Gateway (FastAPI). The AI engine (`ai_engine`) is imported in-process, so
# the image also includes its dependencies (decision A of US-DOCK-001).
# Build context: monorepo root.
#   docker build -f apps/api_gateway/Dockerfile -t autoops-api-gateway .

# ── Stage 1: dependencies ───────────────────────────────────────
FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Only the requirements: the layer stays cached while dependencies do not change.
COPY apps/api_gateway/requirements.txt /tmp/gateway-requirements.txt
COPY services/ai-engine/requirements.txt /tmp/ai-engine-requirements.txt
RUN pip install -r /tmp/gateway-requirements.txt -r /tmp/ai-engine-requirements.txt

# Packaging tools are not needed at runtime. setuptools vendors jaraco.context and wheel, which Trivy flags
# (CVE-2026-23949, CVE-2026-24049): removing them from the venv keeps them out of the runtime image.
RUN pip uninstall -y pip setuptools wheel

# ── Stage 2: minimal runtime ─────────────────────────────────────
FROM python:3.11-slim AS runtime

# Unprivileged user with no login shell.
RUN groupadd --system --gid 10001 autoops \
    && useradd --system --uid 10001 --gid autoops --no-create-home \
        --shell /usr/sbin/nologin autoops

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=autoops:autoops apps/__init__.py ./apps/__init__.py
COPY --chown=autoops:autoops apps/api_gateway ./apps/api_gateway
COPY --chown=autoops:autoops services/ai-engine/ai_engine ./services/ai-engine/ai_engine

# PYTHONUNBUFFERED: immediate logs to stdout/stderr. HOST/PORT are container
# defaults; at runtime they are overridden from the environment.
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONPATH=/app:/app/services/ai-engine \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HOST=0.0.0.0 \
    PORT=8000

USER autoops

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/health', timeout=4)"]

# Shell + exec form: expands the variables from the environment and leaves uvicorn as PID 1.
# --proxy-headers with --forwarded-allow-ips: X-Forwarded-For is honoured only from the proxy
# (docker-compose.yml sets FORWARDED_ALLOW_IPS to Traefik's address), so request.client is the real
# client and cannot be spoofed by any other peer. The login rate limit relies on it.
ENV FORWARDED_ALLOW_IPS=127.0.0.1
CMD ["sh", "-c", "exec uvicorn apps.api_gateway.main:app --host \"$HOST\" --port \"$PORT\" --proxy-headers --forwarded-allow-ips \"$FORWARDED_ALLOW_IPS\""]
