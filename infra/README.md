# Host provisioning (Phase 4)

Everything needed to turn a clean **Ubuntu Server 26.04** into the AutoOps host, and to prove it is configured as
intended. Idempotent Bash, no Ansible. Entry points live in `scripts/provision/`; configuration templates live in
the per-topic folders below.

| Folder | Topic (user story) |
|---|---|
| [`ssh/`](ssh/README.md) | Key-only SSH, restricted deploy key, automatic rollback (HOST-002) |
| [`fail2ban/`](fail2ban/README.md) | SSH brute-force protection (HOST-003) |
| [`firewall/`](firewall/README.md) | UFW deny-by-default and Docker ↔ UFW coherence (NET-001, NET-002) |
| `sysctl/` | Kernel parameters (SYS-001) |
| [`docker/`](docker/README.md) | Docker Engine and hardened `daemon.json` (SYS-002) |
| [`systemd/`](systemd/README.md) | `autoops` service, migrations unit, backup timer (SYS-003) |
| [`backup/`](backup/README.md) | PostgreSQL backups and restore (SYS-004) |
| [`traefik/`](traefik/README.md) | Reverse proxy: single entry point, path routing (Phase 5, PROXY-001) |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/provision/bootstrap.sh` | Runs the steps below in dependency order; stops at the first failure |
| `scripts/provision/verify.sh` | Runs every `checks/*.sh` (read-only), prints an OK/FAIL table, exits `1` on any failure |
| `scripts/provision/provision.env.example` | Every variable, documented. Copy to `provision.env` (ignored by git, no secrets) |

Bootstrap order: `10_users → 20_ssh → 30_fail2ban → 40_ufw → 50_os_baseline → 60_docker → 45_docker_ufw → 70_systemd`.
`45_docker_ufw` runs after Docker is installed despite its number. Each step has a matching `checks/NN_*.sh`;
`checks/80_backup.sh` verifies the backup timer installed by `70_systemd`.

## Full cycle on a clean VM

1. **Snapshot** a fresh Ubuntu Server 26.04 install (VirtualBox) so the cycle can be repeated from zero.
2. **Deploy the repository** to `APP_DIR` (default `/opt/autoops`) and create `${APP_DIR}/.env` from `.env.example`
   (set real `SECRET_KEY` and `DB_PASSWORD`, plus `BACKUP_DIR`, `BACKUP_RETENTION_DAYS`, `BACKUP_SCHEDULE`).
3. **Fill the variables**:
   ```bash
   cp scripts/provision/provision.env.example provision.env && chmod 600 provision.env
   # set ADMIN_USER, ADMIN_SSH_PUBKEY_FILE, FAIL2BAN_IGNOREIP; STACK_REQUIRED=0 until the stack has started once
   ```
4. **Bootstrap**:
   ```bash
   sudo ./scripts/provision/bootstrap.sh --env-file provision.env
   ```
5. **Confirm SSH.** `20_ssh.sh` arms an automatic rollback (30 min under bootstrap). From a **second terminal** log in
   with your key, then:
   ```bash
   sudo ADMIN_USER=<user> ./scripts/provision/20_ssh.sh --confirm      # or re-run bootstrap with --confirm-ssh
   ```
6. **Idempotency.** Run step 4 again: it must end with `Sin cambios` and arm no rollback.
7. **Start and migrate** (first start only): `sudo systemctl start autoops`, then `sudo systemctl start autoops-migrate`.
8. **Verify**: `sudo ./scripts/provision/verify.sh --env-file provision.env` (use `-q` for failures only). Remove
   `STACK_REQUIRED=0` so the runtime checks run too.
9. **Reboot** (`sudo reboot`), wait for the host, and repeat step 8: all groups must still be `OK` and
   `docker compose ps` must show every service `healthy`.
10. **End to end**: from the VM, `venv/bin/python scripts/ops/e2e_https.py --ca /opt/autoops/tls/ca/ca.crt`
    (set `E2E_CONNECT_ADDR=127.0.0.1` if `DOMAIN` does not resolve locally). It follows the `http`→`https`
    redirect, creates a ticket over `https://` and waits for the agents' events over `wss://`. To use the dashboard
    from the host's browser, import the local CA (see [`traefik/README.md`](traefik/README.md)), map `DOMAIN` in
    the client's hosts file and open `https://<DOMAIN>`. UFW and `DOCKER-USER` open only the proxy ports
    (`PROXY_HTTP_PORT` / `PROXY_HTTPS_PORT`, 80/443 by default), so this also works from another machine.

To prove `verify.sh` detects drift, alter a control (e.g. `sudo ufw disable`), run it (expect exit `1` and a `FAIL`
row), then restore the control.

## Notes

- `bootstrap.sh` refuses to run on anything but Ubuntu 26.04, as root, and without the required variables
  (`ADMIN_USER`, `ADMIN_SSH_PUBKEY_FILE`, `FAIL2BAN_IGNOREIP`). Nothing is touched before those checks pass.
- It never cancels the SSH rollback by itself unless `--confirm-ssh` is given.
- Out of scope: instance provisioning (Terraform), auditd/Lynis. TLS is served by Traefik (US-PROXY-002, [`traefik/README.md`](traefik/README.md)); CI/CD is Epic 14.
