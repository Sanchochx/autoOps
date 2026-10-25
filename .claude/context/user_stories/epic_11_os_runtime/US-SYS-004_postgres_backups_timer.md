# US-SYS-004: PostgreSQL Backups with systemd Timer

**Epic:** 11 — OS Hardening & Runtime
**Priority:** HIGH
**Estimate:** 5 pts
**Dependencies:** US-SYS-003
**Status:** Completed

---

## User Story

**As** the server administrator,
**I need** automatic, rotated and restorable database backups,
**so that** I can recover tickets after a disk failure, a human error or a faulty migration.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: Backup Script**
  - `scripts/ops/backup_postgres.sh` runs `pg_dump` (custom format) via `docker compose exec -T postgres`, reading credentials from the environment, without printing them in logs or passing them through visible arguments.
  - Output to `BACKUP_DIR` (variable, outside `postgres_data`) with a dated name, mode `0600` and owner `autoops`.
  - **Verification:** a valid dump is generated (`pg_restore --list`).

- [x] **AC-2: `autoops-backup.service` and `.timer`**
  - Units in `infra/systemd/`: oneshot service and timer (`OnCalendar` via variable, `Persistent=true`, `RandomizedDelaySec`).
  - **Verification:** `systemctl list-timers` shows the next trigger and `systemctl start autoops-backup` creates a backup.

- [x] **AC-3: Retention and Failure Alerts**
  - Rotation by age/count (`BACKUP_RETENTION_DAYS`), deleting only files matching the name pattern. Non-zero exit on failure so systemd records it as `failed`.
  - **Verification:** with reduced retention, old dumps are deleted and recent ones are kept.

- [x] **AC-4: Tested and Documented Restore**
  - Procedure in `infra/backup/README.md` and script `scripts/ops/restore_postgres.sh` with explicit confirmation (destructive operation).
  - Check `scripts/provision/checks/80_backup.sh` (timer active, directory permissions).
  - **Verification:** restore a dump into a clean database and verify that the tickets match.

---

## Technical Notes

- **Out of scope:** remote/S3 backups, dump encryption, PITR/WAL archiving.
- **Disk:** size `BACKUP_DIR` and document the recommended location (separate volume on EC2).
