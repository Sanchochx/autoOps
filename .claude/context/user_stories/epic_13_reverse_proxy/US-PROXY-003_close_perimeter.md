# US-PROXY-003: Close the Perimeter

**Epic:** 13 — Reverse Proxy & TLS
**Priority:** HIGH
**Estimate:** 3 pts
**Dependencies:** US-PROXY-002
**Status:** Pending

---

## User Story

**As** a DevOps engineer,
**I need** the host firewall (UFW and the `DOCKER-USER` chain) to expose only the proxy's HTTP/HTTPS ports and the legacy `PORT`/`FRONTEND_PORT` to be retired from provisioning,
**so that** Traefik is demonstrably the only way into the stack and the exposure left open since US-NET-001/002 is finally closed.

---

## Decisions

- **Single source of truth for the public ports:** the proxy's own variables, `PROXY_HTTP_PORT` and `PROXY_HTTPS_PORT`. Provisioning derives `UFW_WEB_PORTS` and `DOCKER_PUBLIC_PORTS` from them (or from `APP_ENV_FILE`), so changing the published port in the compose cannot leave the firewall out of sync.
- **Deny-by-default stays.** Nothing else is opened: the gateway, frontend, MCP servers and database stay unreachable from outside, as already enforced by the compose (no `ports:` on them).
- **`PORT` is not removed from the application:** the gateway still listens on it inside `edge_net`. What is retired is its role as a *public host port* in provisioning. `FRONTEND_PORT` is removed entirely (the compose no longer reads it).
- **Backward compatibility is explicit, not silent:** if `DOCKER_PUBLIC_PORTS` still contains `PORT` or `FRONTEND_PORT` values, provisioning warns instead of silently keeping them open.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: UFW Opens Only the Proxy Ports**
  - `40_ufw.sh` defaults `UFW_WEB_PORTS` to `PROXY_HTTP_PORT` and `PROXY_HTTPS_PORT` read from `APP_ENV_FILE` (explicit values still win and are still validated by `validate_ufw_inputs`). `provision.env.example` documents it.
  - Still idempotent: a second run reports "Sin cambios"; SSH rules and `ADMIN_CIDR` behavior are untouched.
  - **Verification:** dry-run/rule rendering with the helpers in `lib/ufw_rules.sh` for default and custom ports; on the VM, `ufw status` lists SSH plus the two proxy ports and nothing else.

- [x] **AC-2: `DOCKER-USER` Chain Coherent with the Proxy**
  - `45_docker_ufw.sh` and `lib/docker_ufw_rules.sh`: the default of `DOCKER_PUBLIC_PORTS` becomes the proxy ports (no longer `PORT` + `FRONTEND_PORT`). Containers' published ports follow the same variables as the compose (`${PROXY_HTTP_PORT:-80}`, `${PROXY_HTTPS_PORT:-443}`).
  - Warning when the resolved list includes `PORT`/`FRONTEND_PORT` from `APP_ENV_FILE`.
  - **Verification:** `DOCKER_UFW_DRY_RUN=1` prints a block that accepts only the proxy ports; applied twice on the VM, the second run reports the block up to date.

- [x] **AC-3: Retire `FRONTEND_PORT` and Legacy References**
  - Remove `FRONTEND_PORT` from `.env.example`, `provision.env.example`, `validate_env.sh` and docs; reword `PORT` as the gateway's internal listening port.
  - Update `infra/firewall/README.md` (the "until Phase 5" paragraph), `infra/README.md` and `infra/traefik/README.md` (no more "UFW does not open 80/443 yet" notes), and `CLAUDE.md` if it still mentions them.
  - **Verification:** `grep -rn FRONTEND_PORT` returns only historical user stories and summaries plus the deprecation warnings of the provisioning scripts (`lib/docker_ufw_rules.sh`, `provision.env.example`), which name it on purpose to flag stale `.env` files; `docker compose config` and `validate_env.sh` still pass.

- [ ] **AC-4: `verify.sh` Proves the Perimeter**
  - Extend `checks/40_ufw.sh` and `checks/45_docker_ufw.sh` (no new check unless needed): UFW allows exactly SSH + proxy ports; `DOCKER-USER` accepts exactly the proxy ports; no container other than Traefik publishes a host port (`docker ps --format '{{.Names}} {{.Ports}}'`); `PORT` and `FRONTEND_PORT` values are not listed as public.
  - `verify.sh` keeps exiting `1` on any failure and the new checks fail when a port is added by hand (negative test).
  - **Verification:** `sudo ./scripts/provision/verify.sh` green on the VM; after temporarily adding `ports:` to a service (or a rule to UFW) it goes red and names the offending port.

- [ ] **AC-5: External Validation and Closing**
  - From another machine (or the VirtualBox host): `https://$DOMAIN/` works (with the local CA), `http://` redirects, and `PORT`, `FRONTEND_PORT`, the database and MCP ports time out or are refused.
  - Evidence documented in `infra/firewall/README.md`; plan updated (Epic 13 at 100%, Phase 5 at 3/8).
  - **Verification:** `nmap -p- <vm-ip>` from outside shows only SSH (per `ADMIN_CIDR` policy) and the proxy ports.

---

## Technical Notes

- **Ordering:** run `40_ufw.sh` and `45_docker_ufw.sh` after the compose is up with the new ports; `bootstrap.sh` already orders them, and a re-run is the upgrade path for an existing host.
- **Lockout risk:** the SSH rule and `ADMIN_CIDR` logic must not change; test the rule diff before reloading UFW, as `45_docker_ufw.sh` already does for the Docker block (syntax check, backup, rollback).
- **HSTS and local testing:** from a browser outside the VM, map `DOMAIN` in the hosts file and import `ca.crt` (see `infra/traefik/README.md`).
- **Out of scope:** CI/CD (Epic 14); rate limiting or WAF in the proxy; IPv6 firewall changes beyond what UFW already manages.
