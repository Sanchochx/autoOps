# US-PROV-001: Idempotent Bootstrap and Host Verification

**Epic:** 12 — Provisioning
**Priority:** HIGH
**Estimate:** 8 pts
**Dependencies:** US-HOST-001, US-HOST-002, US-HOST-003, US-NET-001, US-NET-002, US-SYS-001, US-SYS-002, US-SYS-003, US-SYS-004
**Status:** Completed

---

## User Story

**As** a DevOps engineer,
**I need** a single entry point that provisions a clean Ubuntu Server and another that verifies all security controls,
**so that** I can reproduce the server identically on the VirtualBox VM and on AWS EC2 and detect any deviation.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: `bootstrap.sh` Orchestrator**
  - `scripts/provision/bootstrap.sh` runs the numbered scripts in order (`10_users` → `70_systemd`, `80_backup`), with `set -euo pipefail`, prior validation of required variables (fails with a clear message if any is missing), a check that it runs as root/sudo and that the OS is Ubuntu 26.04.
  - Critical order: key-based SSH and UFW (allowing SSH) before closing off access; `45_docker_ufw` after Docker.
  - **Verification:** full run on the clean VM without errors.

- [x] **AC-2: Idempotency and Documented Variables**
  - Template `scripts/provision/provision.env.example` with all variables (admin, keys, CIDR, ports, backups) and a description; no secrets in the repository.
  - **Verification:** a second bootstrap run produces no changes ("no changes" output) or errors.

- [x] **AC-3: Unified `verify.sh`**
  - `scripts/provision/verify.sh` runs all `checks/*.sh`, prints an `OK`/`FAIL` table per control and returns a non-zero code if anything fails.
  - **Verification:** passes on the provisioned VM and fails when a control is manually altered (e.g. `PasswordAuthentication yes` or `ufw disable`).

- [x] **AC-4: Clean VM Validation and Documentation**
  - Full cycle documented in `infra/README.md`: clean Ubuntu 26.04 VM snapshot → bootstrap → `verify.sh` → reboot → stack `healthy` → end-to-end flow from the browser.
  - Update `CLAUDE.md` (monorepo structure: `scripts/`, `infra/`) and `README.md`.
  - **Verification:** the full test runs from scratch on a new VM and all checks pass after the reboot.

---

## Technical Notes

- **No Ansible:** project decision; idempotent Bash and explicit verification.
- **Test environment:** VirtualBox with Ubuntu Server 24.04 LTS; EC2 is only the final target and is not validated in this phase.
- **Out of scope:** Terraform/instance provisioning, TLS and reverse proxy and CI/CD (Phase 5), auditd/Lynis (excluded).
