# syntax=docker/dockerfile:1
# Traefik with its configuration baked in (US-PROXY-001). The configuration is immutable and
# independent of host file permissions, and the image can be published to GHCR (Phase 5, CI/CD).
# Build context: infra/traefik. Nothing configurable lives here: DOMAIN and GATEWAY_PORT are
# read from the environment by dynamic/routes.yml at runtime.
ARG TRAEFIK_VERSION=v3.7.16
FROM traefik:${TRAEFIK_VERSION}

COPY traefik.yml /etc/traefik/traefik.yml
COPY dynamic/ /etc/traefik/dynamic/

# The container runs as an unprivileged UID (set in docker-compose.yml): the files must be
# world-readable whatever the mode they had in the build context.
RUN chmod -R a+rX /etc/traefik
