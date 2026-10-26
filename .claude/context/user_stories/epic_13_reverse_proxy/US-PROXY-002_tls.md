# US-PROXY-002: TLS: Local CA with Self-Signed Certificates and Let's Encrypt HTTP-01

**Epic:** 13 — Reverse Proxy & TLS
**Priority:** HIGH
**Estimate:** 8 pts
**Dependencies:** US-PROXY-001, US-SYS-003
**Status:** In progress

---

## User Story

**As** a DevOps engineer,
**I need** the proxy to serve everything over HTTPS, with a certificate from a local CA on the VirtualBox host and from Let's Encrypt (HTTP-01) in production, selectable by environment variables,
**so that** the local environment is a faithful clone of production (HTTP→HTTPS redirect, `wss://`, security headers) and enabling real certificates is a configuration change, not a code change.

---

## Decisions

- **Local CA, not a lone self-signed certificate.** Provisioning creates a root CA and signs a leaf certificate for `DOMAIN` with it. The CA certificate can be imported once into the browser/OS of the machine hosting the VM and the dashboard then loads without warnings.
- **The redirect HTTP→HTTPS is mandatory in every mode**, `selfsigned` included.
- **`TLS_MODE` has no default.** It is required (`selfsigned` or `acme`), so a production host can never silently serve a local-CA certificate.
- **The CA private key never reaches the proxy.** Only the leaf certificate and its key are mounted into Traefik; the CA key stays on the host, `root`-only.
- ACME HTTP-01 cannot be completed on the current VM (no public IP or domain): it is validated up to configuration and start-up, not up to issuance.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: Local CA and Leaf Certificate in Provisioning**
  - New idempotent step `scripts/provision/65_tls.sh` (runs after `60_docker`, before `70_systemd`; added to `bootstrap.sh`). Creates, under `TLS_DIR` (default `${APP_DIR}/tls`):
    - a root CA (key `0400 root`, certificate world-readable, long validity);
    - a leaf certificate for `DOMAIN` (SAN: `DOMAIN` plus optional `TLS_EXTRA_SANS`), validity of 365 days, key and certificate in a `server/` directory readable by the proxy's UID `65532` and by nobody else.
  - Re-running changes nothing unless the leaf is missing, expires in less than 30 days or its SAN no longer matches `DOMAIN`; then only the leaf is reissued and the CA is kept. Does nothing when `TLS_MODE=acme`.
  - Matching `checks/65_tls.sh` (wired into `verify.sh`): chain verifies against the CA, SAN contains `DOMAIN`, more than 30 days left, modes and owners as above, CA key absent from `server/`.
  - **Verification:** generation can be run unprivileged against a temporary directory (`openssl verify`, `openssl x509 -text`); on the VM, `bootstrap.sh` twice (second run: "Sin cambios") and `verify.sh`.

- [x] **AC-2: HTTPS Entrypoint with Certificates from Files (`TLS_MODE=selfsigned`)**
  - Traefik gets a `websecure` entrypoint (`:443`); the compose publishes `${PROXY_HTTPS_PORT:-443}:443`. The leaf directory is mounted read-only; the routers of US-PROXY-001 are served on `websecure` with `tls`.
  - The certificate source is chosen by `TLS_MODE` through templating in the baked dynamic configuration (no second image, no code change).
  - **Verification:** `curl --cacert <ca.crt> --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/` returns the frontend and `/api/v1/tickets` the API; `openssl s_client` shows the leaf signed by the local CA; without `--cacert` curl rejects it.

- [x] **AC-3: Mandatory Redirect, HSTS and Forwarded Headers**
  - Entrypoint-level permanent redirect (`301`) `web` → `websecure` in all modes.
  - HSTS through a middleware applied to the routers, `max-age` from `HSTS_MAX_AGE_SECONDS` (default one year), without `includeSubDomains` or `preload`.
  - The gateway trusts the proxy's `X-Forwarded-*` headers (`FORWARDED_ALLOW_IPS`), so any redirect it issues keeps `https`. Justified because the gateway publishes no port and is reachable only from `edge_net`.
  - **Verification:** `curl -si http://$DOMAIN/` answers a permanent redirect (Traefik emits `301`) to `https://…`; the HTTPS response carries `Strict-Transport-Security`; a gateway redirect (e.g. a trailing-slash request under `/api/v1/tickets/`) returns a `Location` with `https://`.

- [ ] **AC-4: Let's Encrypt HTTP-01 Switchable by Environment (`TLS_MODE=acme`)**
  - `certificatesResolvers` for ACME HTTP-01 with `ACME_EMAIL` (required in this mode), `ACME_CA_SERVER` (empty = production; staging URL documented) and storage in a named volume mounted on a directory that exists in the image with owner `65532`, so `acme.json` is writable by the unprivileged proxy and persists across recreation.
  - The HTTP-01 challenge keeps working with the mandatory redirect in place.
  - **Verification (configuration only, no issuance is possible here):** with `TLS_MODE=acme`, `docker compose config` is valid, Traefik starts `healthy`, its log shows the resolver registered and no file-certificate is loaded; invalid combinations are rejected (see AC-5).

- [ ] **AC-5: Public Origin over HTTPS, Validation, End-to-End and Documentation**
  - `.env.example`, `provision.env.example`, `validate_env.sh` and the compose document and enforce: `TLS_MODE` ∈ {`selfsigned`, `acme`}; `ACME_EMAIL` non-empty when `acme`; `PUBLIC_SCHEME=https` required for `acme`; `PROXY_HTTPS_PORT`, `HSTS_MAX_AGE_SECONDS`, `TLS_DIR`, `TLS_EXTRA_SANS`.
  - With `PUBLIC_SCHEME=https` the CORS origin becomes `https://$DOMAIN` and the dashboard opens its socket as `wss://` (already resolved from the page origin).
  - `infra/traefik/README.md` and `infra/README.md` updated, including how to export `ca.crt` and import it on the machine hosting the VM, and how to switch to Let's Encrypt in production. `CLAUDE.md` updated.
  - **Verification:** on the VM, the stack comes `healthy` through `autoops.service` in `/opt/autoops`; a script creates a ticket over `https://` and receives the agents' events over `wss://`, going through the redirect and the local CA.

---

## Technical Notes

- **Permissions:** nothing here may depend on the umask of whoever deploys. The proxy's UID is `65532`; provisioning sets owners and modes explicitly and the check proves them (US-PROXY-001 hit this three times).
- **Firewall:** UFW still does not open 80/443 (US-PROXY-003). Tests run from the VM itself; to test from the host's browser, map `DOMAIN` in its hosts file and open the ports temporarily.
- **HSTS and a local domain:** once a browser has seen HSTS for `DOMAIN` it will refuse plain HTTP for `max-age`. Intended here (the local environment mirrors production); lower `HSTS_MAX_AGE_SECONDS` if that is unwanted.
- **Production `.env`:** `/opt/autoops/.env` needs `TLS_MODE` (and `PUBLIC_SCHEME=https`) before the next restart, otherwise Compose refuses to start with a clear message.
- **Out of scope:** opening 80/443 in UFW and retiring `PORT`/`FRONTEND_PORT` from `DOCKER_PUBLIC_PORTS` (US-PROXY-003); automated certificate rotation of the local leaf beyond re-running the idempotent step; DNS-01.
