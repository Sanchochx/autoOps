# Traefik reverse proxy (US-PROXY-001)

Single entry point of the stack: the only service that publishes a host port. Everything else
(`frontend`, `api-gateway`, `postgres`, `mcp-logs`) is reachable only through Docker networks.

```
browser ──► :PROXY_HTTP_PORT ─► traefik ─┬─ /api, /ws ─► api-gateway:PORT   (REST under /api/v1, WebSocket /ws/stream)
                                         └─ /         ─► frontend:8080
```

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | `FROM traefik:${TRAEFIK_VERSION}` with the configuration baked in (`chmod -R a+rX`), so it never depends on host file permissions. Publishable to GHCR (CI/CD). |
| `traefik.yml` | Static configuration: `web` entrypoint (`:80`), internal `traefik` entrypoint (`:8082`, ping only, never published), JSON logs to stdout/stderr. No `api`/dashboard, no Docker provider. |
| `dynamic/routes.yml` | Routers and services (file provider). `DOMAIN` and `GATEWAY_PORT` are read from the environment with Go templating. |

## Security posture

- The Docker socket is **not** mounted; routes are declared as files, not discovered through labels.
- Runs as UID `65532`, `read_only`, `cap_drop: [ALL]` + `NET_BIND_SERVICE`, `no-new-privileges`.
- Only requests for `Host(DOMAIN)` are routed; any other host gets a `404`.
- `edge_net` is the only network shared with `frontend` and `api-gateway`. `backend_net` and `mcp_net` stay `internal`.

## Configuration (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `DOMAIN` | required | Host name Traefik answers for. Compose and `validate_env.sh` fail without it. |
| `PUBLIC_SCHEME` | `http` | `http` or `https`; with `DOMAIN` it forms the origin allowed by CORS. |
| `PROXY_HTTP_PORT` | `80` | Host port published for HTTP. |
| `TRAEFIK_VERSION` | pinned in `docker-compose.yml` | Image tag used as build arg. |

The frontend is built with same-origin paths (`VITE_API_BASE_URL=/`, `VITE_WS_BASE_URL=/ws`, set in
`docker-compose.yml`); the browser resolves `/ws` against the page origin (`ws://` or `wss://`).

## Operation

```bash
docker compose up -d --build --wait            # builds the traefik image with the stack
docker compose logs -f traefik                 # JSON application and access logs
curl -si -H 'Host: <DOMAIN>' http://127.0.0.1:<PROXY_HTTP_PORT>/          # frontend
curl -si -H 'Host: <DOMAIN>' http://127.0.0.1:<PROXY_HTTP_PORT>/api/v1/tickets
```

To test from a browser, map `<DOMAIN>` to the host IP in the client's hosts file. The host firewall does not
open port 80 until US-PROXY-003; until then, test from the VM itself.

## Out of scope here

TLS, HTTP→HTTPS redirect and HSTS (US-PROXY-002); UFW / `DOCKER_PUBLIC_PORTS` changes (US-PROXY-003).
