# Phase 4 Summary: Linux Infrastructure and Security

**Project:** AutoOps — Self-Hosted Multi-Agent SRE Platform
**Closing date:** 2026-10-25
**Status:** Completed (10/10 US)

| US | Epic | Commit |
|----|------|--------|
| US-HOST-001 Native users and privilege model | 09 | `77598d3` |
| US-HOST-002 SSH hardening and key management | 09 | `b9294c7` |
| US-HOST-003 Brute-force protection (fail2ban) | 09 | `b0eeb56` |
| US-NET-001 UFW deny-by-default | 10 | `b67fa24` |
| US-NET-002 Docker ↔ UFW coherence | 10 | `99c0896` |
| US-SYS-001 OS baseline and automatic patching | 11 | `5dac1ee` |
| US-SYS-002 Docker Engine and hardened `daemon.json` | 11 | `1a037a4` |
| US-SYS-003 systemd service for the stack | 11 | `c2ea9e0` |
| US-SYS-004 PostgreSQL backups with systemd timer | 11 | `10a5d56` |
| US-PROV-001 Idempotent bootstrap and host verification | 12 | see `git log` (PROV-001) |

---

## 📝 Changes Made

- **Access:** `root` locked, `sudo` admin without Docker, `autoops` service user (UID/GID 1500, `nologin`, only in `docker`); key-only ed25519 SSH with an automatic rollback; restricted CI/CD deploy key; fail2ban on journald.
- **Network:** UFW deny-by-default with the SSH rule added before enabling; `DOCKER-USER` rules so ports published by Docker respect the firewall.
- **Runtime:** OS baseline (unattended upgrades, sysctl), Docker Engine from the official repo with a hardened `daemon.json`, `autoops.service` (starts the stack at boot) and a manual `autoops-migrate.service`.
- **Backups:** `pg_dump` custom format every `BACKUP_SCHEDULE`, rotated by `BACKUP_RETENTION_DAYS`, failures surface as a `failed` unit; `restore_postgres.sh` is transactional and requires a terminal plus typing `CONFIRMAR`.
- **Provisioning:** `bootstrap.sh` (dependency order, preflight, stops on first failure, reports "Sin cambios" on a no-op re-run) and `verify.sh` (all `checks/*.sh`, OK/FAIL table, exit 1 on any failure).

## 🔎 Findings During Validation

- `checks/10_users.sh` forbade any extra group for `autoops`, contradicting `60_docker.sh`/`70_systemd.sh`; it now allows `docker`.
- `70_systemd.sh` reported a change on every run: a unit without `[Install]` makes `systemctl is-enabled` exit 0 (`static`). It now compares the state text.
- `bootstrap.sh` always said the SSH rollback was armed; it now checks the timer.
- Target OS is **Ubuntu 26.04** (the real VM), not 24.04 as first written. `infra/ssh` notes about `ssh.socket` were written for 24.04 and were not re-verified.

## ⚠️ Known Gaps

- The reboot test and the browser end-to-end flow of US-PROV-001 AC-4 are documented in `infra/README.md` but were not reported back as run in the review session.
- The restore comparison of US-SYS-004 was first run against a database without schema; the README states that migrations must be applied.
- Backups live on the same disk; off-host copy and dump encryption are out of scope.

## 🚀 Next Steps

**Phase 5: Secure Exposure and CI/CD** — Traefik/Nginx with Let's Encrypt and GitHub Actions deploying over the restricted SSH key. No user stories written yet; they are drafted and validated before starting. Decide first how `PORT`/`FRONTEND_PORT` stop being public once the proxy fronts them (`DOCKER_PUBLIC_PORTS`, `UFW_WEB_PORTS`).
