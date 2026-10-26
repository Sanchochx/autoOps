# syntax=docker/dockerfile:1
# Frontend (React + Vite). Built with Node and served as static files by
# unprivileged Nginx. Build context: apps/frontend.
#   docker build -t autoops-frontend \
#     --build-arg VITE_API_BASE_URL=http://localhost:8000 \
#     --build-arg VITE_WS_BASE_URL=ws://localhost:8000/ws \
#     apps/frontend

# ── Stage 1: build ──────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Vite embeds the VITE_* variables in the bundle at build time (they are public: no secrets).
ARG VITE_API_BASE_URL
ARG VITE_WS_BASE_URL
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL \
    VITE_WS_BASE_URL=$VITE_WS_BASE_URL

# Manifests only: the dependency layer stays cached as long as they do not change.
COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# ── Stage 2: runtime ────────────────────────────────────────────
FROM nginx:alpine AS runtime

# Full Nginx configuration (replaces the default one, which requires root).
# --chmod: COPY keeps the source mode, and the unprivileged `nginx` user must be able to read it
# whatever the umask of the machine that builds the image.
COPY --chmod=0644 nginx.conf /etc/nginx/nginx.conf
COPY --from=builder /app/dist /usr/share/nginx/html

# Writes only to /tmp (pid and temp files, see nginx.conf); the content is read-only.
USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/"]

CMD ["nginx", "-g", "daemon off;"]
