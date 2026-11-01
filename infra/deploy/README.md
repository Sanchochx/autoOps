# Pull-based deployment (US-CICD-004)

How a commit that reached `main` becomes the running stack on the AutoOps host **without GitHub (or the runner) ever
holding a way into the host**. The runner only leaves a small request file; the host validates it, pulls the published
images itself and applies them. Everything in this document was exercised on the VM (see [Evidence](#evidence)).

## Flow

```
workflow job (self-hosted runner, container)         host (systemd, user `autoops`)
────────────────────────────────────────────         ──────────────────────────────
scripts/ci/request_deploy.sh                          autoops-deploy.path   (PathExists=<inbox>/request)
  writes tag=<sha> / run_id=<n>  ──► inbox (rw)  ──►    └─► autoops-deploy.service  (Type=oneshot)
  polls status                  ◄── outbox (ro) ◄──          └─► scripts/ops/deploy.sh --request-file <inbox>/request
```

`deploy.sh` runs, in this order (a failure before step 6 changes neither `.env` nor the running stack):

1. Parse the request (untrusted input, see [Request format](#request-format)). It is deleted as soon as it is read.
2. Check the provenance of the SHA with the public GitHub compare API (see [Threat model](#threat-model)).
3. Check that the four images exist in the registry (`docker manifest inspect`, nothing is pulled).
4. `docker compose pull` with `IMAGE_TAG` set only in the environment of that command.
5. Start `postgres`, take a backup (`backup_postgres.sh`, kept in `BACKUP_DIR`) and run the migrations.
6. **Point of no return:** rewrite `IMAGE_TAG` in `.env`, `docker compose up -d --wait`, then probe
   `https://$DOMAIN$DEPLOY_HEALTH_PATH` (default `/api/v1/tickets`, 200 expected) up to `DEPLOY_HEALTH_RETRIES` times.
7. Success: `current` ← new tag, `previous` ← old tag. Failure: put the previous tag back and `up` + probe again.

Only one deploy runs at a time: the unit is `Type=oneshot`, `deploy.sh` also holds an `flock`, and a request that arrives
while one is running stays in the inbox until the service stops (the path unit checks again then).

## Request format

A regular file `request` in the inbox, at most 256 bytes, exactly these two keys, each at most once:

```
tag=<40 lowercase hex characters, the full commit SHA>
run_id=<1 to 20 digits>
```

Anything else (a symlink, an unknown key, a duplicate, CR or NUL bytes, a bad value) is rejected with
`reason=invalid_request` and nothing is executed: the values are never passed to a shell. `run_id` is optional for the
host; the runner script always sends it so it can recognise its own answer. The runner writes the file under a temporary
name in the inbox and renames it, so the path unit never sees a half-written request.

## Status format

`status` in the outbox is replaced atomically on every change and contains only fixed codes:

```
state=<running|succeeded|rolled_back|failed>
reason=<none|invalid_request|preflight|provenance_unavailable|provenance_rejected|images_missing|pull_failed|backup_failed|migrate_failed|apply_failed|health_failed|unexpected_error>
rollback=<none|ok|failed>
tag=<sha>  previous=<sha>  run_id=<n>  started_at=<UTC>  finished_at=<UTC>
```

Every outcome is also appended to `<state dir>/history` (`<time> <state> <tag> <run_id> <reason>`), and the logs of each
run are in the journal: `journalctl -u autoops-deploy.service`. `current` and `previous` in the state dir hold the tags
of the running and the preceding release.

| `state` | Meaning | `request_deploy.sh` exit |
|---|---|---|
| `succeeded` | New release healthy | 0 |
| `rolled_back` | New release failed its health gate (or `up`); the previous one is running and healthy | 1 |
| `failed` | Rejected or failed; check `reason` and `rollback` (`failed` = the stack needs manual attention) | 2 |
| (no answer) | Host did not answer in `DEPLOY_WAIT_TIMEOUT`; the request is withdrawn | 3 |

## Threat model

The runner executes workflow code, so it is **not trusted**; the host re-derives everything from public data.

| Threat | Control |
|---|---|
| The runner asks for a malicious or unreviewed build | The SHA must be on `main` (`compare/<sha>...main` is `ahead` or `identical`) and, when a release is running, ahead of it (no downgrade through the runner). The compare API is public: the host holds no token. If it cannot be queried the request fails closed (`provenance_unavailable`, which also covers a SHA GitHub does not know). |
| Command injection through the request | Strict parser, 256 bytes, two keys, values matched against `^[0-9a-f]{40}$` / `^[0-9]{1,20}$`; the file is opened once and checked to be the same inode as the path (no symlink swap). |
| The runner forges a status | The outbox is a read-only mount in the container. |
| The runner reaches the host | Only the two spool mounts exist (guarded in CI by `check_runner_compose.sh`); no `docker.sock`, no host network. |
| Deploying images that do not exist or a half-pulled release | Registry check before the pull; `.env` is not touched until the pull, backup and migration succeeded. |
| Two deploys at once | `oneshot` unit plus `flock`. |
| A stale answer taken for the current one | `request_deploy.sh` accepts only a status whose `run_id` and `tag` match and that started after the request was written. |

The host user is in the `docker` group (root-equivalent for Docker, not for SSH, UFW or packages); the unit adds
`NoNewPrivileges`, `ProtectSystem=full`, an empty capability set and `ReadWritePaths` limited to the app, backups and spool.

## Operations

All commands on the host, from `/opt/autoops`.

```bash
journalctl -u autoops-deploy.service -n 50 --no-pager -o cat    # what the last run did
sudo cat /opt/autoops/.deploy/outbox/status                     # its outcome
sudo cat /opt/autoops/.deploy/history                           # every outcome
sudo docker ps --format '{{.Names}}\t{{.Image}}'                # what is running (tag = the commit SHA)
```

### Deploy by hand, or roll back to a release

The operator mode takes an exact SHA, skips the ancestry check (so going back is allowed) but not the registry check:

```bash
sudo -u autoops ./scripts/ops/deploy.sh --tag <40-hex sha> --dry-run   # validate and print the plan, change nothing
sudo -u autoops ./scripts/ops/deploy.sh --tag <40-hex sha>
```

The previous release is in `/opt/autoops/.deploy/previous` (readable by `autoops` only). A manual run records `run_id=manual`. Do not override
`DEPLOY_HEALTH_PATH` to make a drill fail: the rollback uses the same probe and would fail too (see Evidence).

### When `rollback=failed` or the stack is unhealthy

The images are restored first; look at `docker compose ps` and `docker compose logs --tail 100 <service>`, fix the cause
and run `deploy.sh --tag <current or previous sha>` again. If a service is down because of the data, restore the backup
below.

### Restore the pre-deploy backup

Every deploy takes a dump before migrating (`autoops_db_<timestamp>.dump` in `BACKUP_DIR`, the path is in the journal).
Restoring is destructive and asks for confirmation; the full procedure (including trying a backup on a scratch database)
is in [`../backup/README.md`](../backup/README.md#restore):

```bash
./scripts/ops/restore_postgres.sh                              # lists the dumps
./scripts/ops/restore_postgres.sh autoops_db_<timestamp>.dump
```

### The schema limit

A rollback restores **images only**. Migrations are not reverted, so the previous release must run on the migrated
schema: ship schema changes as expand/contract (add first, remove in a later release once nothing reads the old shape).
If a migration is destructive, rolling back may need the backup above.

### GHCR package visibility

The host pulls without credentials while the packages are `public`, which they are as long as the repository is. Check
it the way the host would, anonymously (expect `200`; `401`/`403`/`404` means the host cannot pull):

```bash
SHA=<40-hex sha>
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:<owner>/autoops/api-gateway:pull" | jq -r .token)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json' \
  "https://ghcr.io/v2/<owner>/autoops/api-gateway/manifests/$SHA"
```

`<owner>` in lowercase. If the repository goes private, the host needs `docker login ghcr.io` with a `read:packages`
token (see [`../ci/README.md`](../ci/README.md#package-visibility-and-pull-credentials)).

## Tests

| What | Where |
|---|---|
| Deploy flow with a fake `docker`/`curl` (success, failed pull, backup, migrate and `up`, failed health gate with rollback, first deploy) and the guards (parser, provenance, registry) | `scripts/ci/test_deploy.sh`, CI job `deploy-guards` |
| Runner side (exit codes, stale status, timeout, injection) | `scripts/ci/test_request_deploy.sh`, `deploy-guards` |
| The runner Compose keeps exactly the two spool mounts | `check_runner_compose.sh` and `test_runner_compose_guard.sh`, `runner-compose` |
| Spool and units on the host | `scripts/provision/checks/85_deploy.sh` (`verify.sh`) |
| Inside the real container | `runner-smoke.yml` (manual) |

## Evidence

Drills run on the VM on 2026-11-01. Releases: `3087d5d` (PR #6 merge) and `56097f1` (PR #7 merge), both published to GHCR.

| # | Drill | How | Result |
|---|---|---|---|
| 1 | Successful deploy | request from inside the runner container for `3087d5d` | `state=succeeded` (run 1001), four services on `ghcr.io/sanchochx/autoops/<service>:3087d5d…` |
| 2 | Malformed request | extra key `evil=$(touch /tmp/pwned)` | `failed` / `invalid_request` (run 2001), nothing executed |
| 3 | Request for an old SHA | `67dc416` (on `main`, behind the running release) | `failed` / `provenance_rejected` (run 2002) |
| 3b | Unknown SHA | `0000…0` | `failed` / `provenance_unavailable` (fail closed); with `IMAGE_REPOSITORY` unset: `failed` / `preflight` |
| 4 | Failed `pull` | **not reproduced on the VM** (a missing image stops earlier, at `images_missing`) | covered by `test_deploy.sh` with a fake `docker` |
| 5 | Failed health gate | operator run of `56097f1` with `DEPLOY_HEALTH_PATH=/api/v1/no-existe` | pull, backup, migrate and `up` ok; probe 404 twice; images rolled back to `3087d5d` (`docker ps`, `.env` `IMAGE_TAG` and `current` agree; the real endpoint returns 200); but the **same wrong path** was used to probe the rollback, so the outcome was `failed` / `health_failed` / `rollback=failed`. That is the "stack needs manual attention" branch. A clean `rolled_back` needs a failure that only the new release has and is covered by `test_deploy.sh`, not reproduced on the VM. |
| 6 | Two concurrent requests | runs 3001 and 3002 for the running tag, sent back to back | processed one after the other (the second started when the first finished); both `succeeded` |
