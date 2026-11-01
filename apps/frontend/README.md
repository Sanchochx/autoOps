# AutoOps — Dashboard (React + Vite + TypeScript + TailwindCSS)

## Development

```bash
cd apps/frontend
npm install
npm run dev      # port from VITE_DEV_SERVER_PORT (.env); Vite's default otherwise
npm run build
```

Variables (see `.env.example` at the root): `VITE_API_BASE_URL`, `VITE_WS_BASE_URL`, `VITE_DEV_SERVER_PORT`.

## Docker

Multi-stage image: `node:20-alpine` builds the bundle and `nginx:alpine` serves it as
static files with the unprivileged `nginx` user. The final image contains neither Node nor `node_modules`.

### Build args

Vite embeds the `VITE_*` variables **at build time**, so they are passed as
`--build-arg` and not as container environment variables. Changing them requires rebuilding the image.
They are public (visible in the bundle): never include secrets.

| Build arg | Description | Example |
|---|---|---|
| `VITE_API_BASE_URL` | Base URL of the Gateway REST API | `http://localhost:8000` (standalone), `/` (behind the proxy) |
| `VITE_WS_BASE_URL` | Base URL of the Gateway WebSockets | `ws://localhost:8000/ws` (standalone), `/ws` (behind the proxy) |
| `VITE_TICKETS_POLL_INTERVAL_MS` | Ticket list polling in ms (`0` disables) | `5000` (default; Compose reads it from `.env`) |

Behind Traefik (Docker Compose) both are same-origin paths set in `docker-compose.yml`, not read from `.env`.
A path is resolved against the page origin, so the socket uses `wss://` when the page is served over HTTPS.

### Ticket management

The dashboard creates (`POST /api/v1/tickets`, always with `severity: "medium"`; the Triage Agent assigns the real one)
and lists (`GET /api/v1/tickets`) tickets next to the live agent console. Requests use the relative path joined to
`VITE_API_BASE_URL`, so behind the proxy they stay same-origin. The list polls every
`VITE_TICKETS_POLL_INTERVAL_MS` ms (default 5000, `0` disables; paused while the tab is hidden). Tests: `npm test` (Vitest).

```bash
docker build -t autoops-frontend \
  --build-arg VITE_API_BASE_URL=http://localhost:8000 \
  --build-arg VITE_WS_BASE_URL=ws://localhost:8000/ws \
  apps/frontend

docker run --rm -p 3000:8080 autoops-frontend   # http://localhost:3000
```

The container listens on port **8080**. The origin it is served from (e.g.
`http://localhost:3000`) must be listed in the Gateway's `CORS_ALLOWED_ORIGINS`.
