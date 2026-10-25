# US-PROXY-001: Traefik as the Single Entry Point (HTTP) and Compose Integration

**Epic:** 13 — Reverse Proxy & TLS
**Priority:** HIGH
**Estimate:** 5 pts
**Dependencies:** US-DOCK-004, US-NET-002
**Status:** In progress

---

## User Story

**As** a DevOps engineer,
**I need** a reverse proxy that is the only service of the stack publishing host ports,
**so that** TLS can be added (US-PROXY-002) and the direct ports of the gateway and the frontend can be closed (US-PROXY-003) without touching the application.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [ ] **AC-1: Traefik Service in Compose**
  - `traefik` service with a pinned image version. Static and dynamic configuration under `infra/traefik/` (file provider; the Docker socket is NOT mounted).
  - New bridge network `edge_net`. Hardening: `read_only`, `cap_drop: [ALL]` plus `NET_BIND_SERVICE`, `no-new-privileges`. Dashboard disabled, JSON logs to stdout/stderr, no local log files.
  - Healthcheck through Traefik's `ping` endpoint.
  - **Verification:** `docker compose config` is valid, the container is `healthy` and its mounts do not include `docker.sock`.

- [ ] **AC-2: Path Routing and Removal of Direct Ports**
  - `/` routes to `frontend`; `/api` and `/ws` route to `api-gateway`, including the WebSocket upgrade.
  - `frontend` and `api-gateway` join `edge_net` and lose their `ports:`. Only Traefik publishes a host port (80 at this stage).
  - **Verification:** `curl -H "Host: $DOMAIN"` returns the frontend on `/` and the gateway on its API/health routes; direct access to `PORT` and `FRONTEND_PORT` fails.

- [ ] **AC-3: Same-Origin Configuration**
  - New variables (`DOMAIN`, Traefik image version, published HTTP port) in `.env.example`, `scripts/ops/validate_env.sh` and, where applicable, `scripts/provision/provision.env.example`.
  - `VITE_API_BASE_URL`, `VITE_WS_BASE_URL` and `CORS_ALLOWED_ORIGINS` documented for the single-origin model.
  - No domains, ports or routes hardcoded in the Traefik configuration: everything comes from the environment.
  - **Verification:** the stack refuses to start with a clear message if `DOMAIN` is missing.

- [ ] **AC-4: End-to-End Validation and Documentation**
  - The stack comes up `healthy` through `autoops.service`. The dashboard loads through Traefik, a ticket is created and the reasoning stream arrives over WebSocket.
  - `infra/traefik/README.md` written; `CLAUDE.md` (monorepo structure, `edge_net`) updated.
  - **Verification:** full flow on the VM over HTTP.

---

## Technical Notes

- **Firewall:** UFW does not open port 80 until US-PROXY-003. Until then, test from the VM itself, or add the port to `DOCKER_PUBLIC_PORTS` temporarily. The firewall is not modified in this US.
- **`internal` networks:** `backend_net` and `mcp_net` stay `internal`. Traefik only joins `edge_net`.
- **Prepared for TLS:** the static configuration is laid out so that US-PROXY-002 adds the `websecure` entrypoint and the certificate source (self-signed locally, Let's Encrypt HTTP-01 in production) without restructuring it.
- **Out of scope:** TLS, HTTP→HTTPS redirect, HSTS (US-PROXY-002); UFW and `DOCKER_PUBLIC_PORTS` changes and `verify.sh` checks (US-PROXY-003).
