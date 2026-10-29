# systemd units (US-SYS-003)

| Unit | Purpose |
|---|---|
| `autoops.service` | `Type=oneshot` + `RemainAfterExit`: `docker compose up -d --wait` / `down`. Enabled at boot. |
| `autoops-migrate.service` | Manual Alembic `upgrade head`. No `[Install]`, never enabled. |
| `autoops-backup.service` / `.timer` | `Type=oneshot` `pg_dump` via `scripts/ops/backup_postgres.sh`; timer uses `BACKUP_SCHEDULE` from `.env` (rendered by `70_systemd.sh`), `RandomizedDelaySec=15min`, `Persistent=true`. |

Install: `sudo ./scripts/provision/70_systemd.sh` (`AUTOOPS_ENABLE=1` also enables boot start).
Check: `sudo ./scripts/provision/checks/70_systemd.sh`.

`autoops.service` runs `scripts/ops/validate_env.sh` as `ExecStartPre=`: with `ENVIRONMENT=production` it refuses to start if `SECRET_KEY` or `DB_PASSWORD` is empty or a default (e.g. `cambia_esta_clave`), or if `IMAGE_TAG` is empty or `dev` (production runs a published commit SHA, see `infra/ci/README.md`).

## Operation

```bash
sudo systemctl start|stop|restart|reload autoops
sudo systemctl start autoops-migrate     # run migrations (stack should be up)
journalctl -u autoops                    # lifecycle; application logs: docker compose logs
```

## Design notes

- **Secrets:** `docker compose` reads `/opt/autoops/.env` (0600, `autoops`) itself; no `EnvironmentFile`, so secrets never enter the unit or the CLI environment.
- **Sandbox scope:** the directives confine the `docker compose` CLI process only. Containers are children of `dockerd`, hardened separately (compose `cap_drop`, `read_only`, `daemon.json`). The `docker` group is root-equivalent, which bounds the achievable `systemd-analyze security` score.
- **Resilience:** `restart: unless-stopped` + `live-restore` keep containers alive across daemon restarts; the unit restores the stack after a host reboot. `systemctl stop` runs `down` (volumes kept).
- **Ordering:** `After=ufw.service` so `DOCKER-USER` rules (US-NET-002) exist before ports are published.
- **Migrations:** `run` starts postgres as a dependency if the stack is down, leaving it running outside the unit; run migrations with `autoops` active.
