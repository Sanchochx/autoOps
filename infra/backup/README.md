# PostgreSQL backups and restore (US-SYS-004)

Backups are `pg_dump` custom-format files (`autoops_db_YYYYMMDD_HHMMSS.dump`, mode `0600`) written to `BACKUP_DIR`
by `scripts/ops/backup_postgres.sh`, scheduled by `autoops-backup.timer`. Dumps older than
`BACKUP_RETENTION_DAYS` are rotated after every successful backup.

| Variable (`.env`) | Meaning |
|---|---|
| `BACKUP_DIR` | Absolute path for dumps (mode `0700`, owner `autoops`). Keep it **outside** the `postgres_data` volume; on EC2 use a separate volume. |
| `BACKUP_RETENTION_DAYS` | Age in days after which dumps are deleted (integer >= 1). |
| `BACKUP_SCHEDULE` | systemd `OnCalendar` expression for the timer. |

Out of scope: remote/S3 copies, dump encryption, PITR/WAL archiving. A dump on the same disk does not protect
against losing the disk: copy `BACKUP_DIR` off the host yourself until that is covered.

## Manual backup

```bash
sudo systemctl start autoops-backup          # same unit the timer runs
# or, without systemd, as the autoops user from the deployment directory:
sudo -u autoops /opt/autoops/scripts/ops/backup_postgres.sh
```

The script prints the path of the new dump. Check it is valid:

```bash
docker compose exec -T postgres pg_restore --list < /opt/autoops/backups/autoops_db_<timestamp>.dump | head
```

## Timer status and logs

```bash
systemctl list-timers autoops-backup.timer   # NEXT / LAST trigger
systemctl status autoops-backup.timer
systemctl status autoops-backup.service      # result of the last run ("failed" = see below)
journalctl -u autoops-backup.service -n 50   # script output (stderr) of recent runs
journalctl -u autoops-backup.service -p err  # only failures
```

Any failure (dump, empty file, rotation, invalid `BACKUP_RETENTION_DAYS`) exits `1`, so the unit shows `failed`.
Fix the cause (disk full, stack down, bad `.env`) and run `sudo systemctl start autoops-backup` again.

Provisioning check: `sudo ./scripts/provision/checks/80_backup.sh`.

## Restore

> **Destructive.** `restore_postgres.sh` replaces the contents of the target database with the dump. It runs
> `pg_restore --clean --if-exists --no-owner --single-transaction` inside the `postgres` container: if anything
> fails the transaction rolls back and the database is left as it was. It always asks you to type `CONFIRMAR`
> and refuses to run without a terminal.

1. **List the dumps** (newest first):
   ```bash
   cd /opt/autoops
   ./scripts/ops/restore_postgres.sh
   ```
2. **Take a safety backup of the current state** (so a wrong choice is reversible):
   ```bash
   sudo systemctl start autoops-backup
   ```
3. **Stop the gateway** to release its database connections (postgres must stay up):
   ```bash
   docker compose stop api-gateway
   ```
4. **Restore** the chosen dump (a bare file name is looked up in `BACKUP_DIR`):
   ```bash
   ./scripts/ops/restore_postgres.sh autoops_db_20261024_030000.dump
   ```
   Read the warning, then type `CONFIRMAR` exactly. Anything else aborts without changes.
5. **Start the gateway again and verify**:
   ```bash
   docker compose start api-gateway
   docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT count(*) FROM tickets;"'
   ```
6. If the dump predates a migration, re-apply it: `sudo systemctl start autoops-migrate`.

### Test a backup without touching production data

Restore into a throw-away database and compare it with the live one:

```bash
docker compose exec -T postgres sh -c 'createdb -U "$POSTGRES_USER" autoops_restore_test'
RESTORE_DB=autoops_restore_test ./scripts/ops/restore_postgres.sh autoops_db_<timestamp>.dump
for db in '$POSTGRES_DB' autoops_restore_test; do
  docker compose exec -T postgres sh -c "psql -U \"\$POSTGRES_USER\" -d $db -Atc 'SELECT count(*), max(created_at) FROM tickets;'"
done
docker compose exec -T postgres sh -c 'dropdb -U "$POSTGRES_USER" autoops_restore_test'
```

Both databases must have the schema applied (`alembic upgrade head`); otherwise `tickets` does not exist and the
comparison proves nothing. The counts match when the dump is current (differences are expected if tickets were created after the backup).
