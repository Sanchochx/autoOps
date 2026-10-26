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
| `traefik.yml` | Static configuration: `web` (`:80`) and `websecure` (`:443`) entrypoints, internal `traefik` entrypoint (`:8082`, ping only, never published), JSON logs to stdout/stderr. No `api`/dashboard, no Docker provider. |
| `dynamic/routes.yml` | Routers and services (file provider), served on `websecure` with `tls`. `DOMAIN` and `GATEWAY_PORT` are read from the environment with Go templating. |
| `dynamic/tls.yml` | Certificate source chosen by `TLS_MODE` (templating): `selfsigned` loads `/etc/traefik/tls/{cert,key}.pem`; `acme` loads none and the routers use the `le` resolver. |
| `entrypoint.sh` | Static configuration cannot read env vars, so with `TLS_MODE=acme` this appends the `le` resolver (HTTP-01 on `web`, storage `/acme/acme.json` in the `acme` named volume) to a copy in `/tmp`, then starts Traefik. |

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
| `PROXY_HTTPS_PORT` | `443` | Host port published for HTTPS. |
| `HSTS_MAX_AGE_SECONDS` | `31536000` | `max-age` of `Strict-Transport-Security` (no `includeSubDomains`/`preload`). |
| `FORWARDED_ALLOW_IPS` | `*` | Peers whose `X-Forwarded-*` the gateway trusts (set on `api-gateway`). |
| `TLS_MODE` | required | `selfsigned` or `acme`. Compose fails without it. |
| `ACME_EMAIL` | empty | Let's Encrypt account email; required when `TLS_MODE=acme` (the entrypoint refuses to start without it). |
| `ACME_CA_SERVER` | empty | Empty = Let's Encrypt production; staging: `https://acme-staging-v02.api.letsencrypt.org/directory`. |
| `TLS_DIR` | `./tls` | Directory created by `scripts/provision/65_tls.sh`; only `server/` (leaf cert + key) is mounted, read-only. The CA key is never mounted. |
| `TRAEFIK_VERSION` | pinned in `docker-compose.yml` | Image tag used as build arg. |

The frontend is built with same-origin paths (`VITE_API_BASE_URL=/`, `VITE_WS_BASE_URL=/ws`, set in
`docker-compose.yml`); the browser resolves `/ws` against the page origin (`ws://` or `wss://`).

## Operation

```bash
docker compose up -d --build --wait            # builds the traefik image with the stack
docker compose logs -f traefik                 # JSON application and access logs
curl --cacert <TLS_DIR>/ca/ca.crt --resolve <DOMAIN>:<PROXY_HTTPS_PORT>:127.0.0.1 https://<DOMAIN>:<PROXY_HTTPS_PORT>/               # frontend
curl --cacert <TLS_DIR>/ca/ca.crt --resolve <DOMAIN>:<PROXY_HTTPS_PORT>:127.0.0.1 https://<DOMAIN>:<PROXY_HTTPS_PORT>/api/v1/tickets
```

`65_tls.sh` writes to `${APP_DIR}/tls` (`/opt/autoops/tls`) unless `TLS_DIR` is set. For a checkout run
outside `/opt/autoops`, generate into the checkout (`TLS_DIR=./tls`) or copy the result with `cp -a` (keeps
owners and modes); otherwise Traefik finds no PEM files and fails to start.

To test from a browser, map `<DOMAIN>` to the host IP in the client's hosts file. The host firewall does not
open port 80 until US-PROXY-003; until then, test from the VM itself.

## Out of scope here

UFW / `DOCKER_PUBLIC_PORTS` changes (US-PROXY-003).
