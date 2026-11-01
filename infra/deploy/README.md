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
reason=<none|invalid_request|preflight|provenance_unavailable|provenance_rejected|images_missing|pull_failed|backup_failed|migrate_failed|apply_failed|health_failed|smoke_failed|unexpected_error>
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

## Continuous delivery (US-CICD-005)

`.github/workflows/deploy.yml` makes the flow above automatic: **merge to `main`, watch the run**. No step reaches Docker
from GitHub.

| Job | Where | What it does |
|---|---|---|
| `wait-for-ci` | GitHub-hosted | Polls the `CI` run of the same commit (every 20 s, up to 30 min) and requires its `ci` and `publish` jobs to be `success`, i.e. tested and the four images in GHCR. A red, cancelled or missing CI ends the workflow here and the host is never asked. |
| `deploy` | self-hosted runner `autoops-prod`, `environment: production` | Checks out the commit and runs `bash scripts/ci/request_deploy.sh`. The exit code of the script is the job result and the outcome goes to the job summary. |

- **Triggers:** `push` to `main` and `workflow_dispatch` (the only ones `check_runner_workflows.sh` allows for a workflow that
  uses the runner). `workflow_dispatch --ref main` redeploys the commit at the tip of `main`; any other branch is refused by
  the environment rule.
- **Order:** `concurrency: deploy` with `cancel-in-progress: false`; two merges in a row queue and a deploy in flight is
  never cancelled. The host also refuses a SHA older than the running release.
- **Exit codes → job result:** `0` green (`succeeded`), `1` red (`rolled_back`: the previous release is running),
  `2` red (`failed`), `3` red (no answer in `DEPLOY_WAIT_TIMEOUT`, 1500 s; the request is withdrawn).
- **Job summary:** `Deploy of <sha>` with the `state`, `reason`, `rollback`, tag and times copied from the fixed-code
  `status`, never raw command output.
- **Smoke test:** `scripts/ops/smoke_test.sh` runs on the host as the last step of the health gate, after the probe, with
  read-only HTTPS requests through Traefik: the frontend answers `200` with HTML; the API answers `200` on
  `DEPLOY_HEALTH_PATH`; `HSTS` is set; HTTP redirects to HTTPS; the `api-gateway` container runs the deployed tag. A failure
  is `reason=smoke_failed` and triggers the normal rollback (which is smoke-tested against the previous image too). It runs on
  the host because the runner cannot reach the stack by design. By hand: see the variables at the top of the script.

### What to do on each red

| The run shows | Look at | Usually |
|---|---|---|
| `wait-for-ci` red | The CI run linked from the job log | Fix the commit. Nothing reached the host; push a fix |
| `deploy` red, exit 3 (no answer) | `systemctl status autoops-deploy.path autoops-runner.service` on the host, then the journal | A stopped unit, or a deploy slower than 25 min |
| `reason=invalid_request` / `preflight` | `journalctl -u autoops-deploy.service -n 40 -o cat` | Spool or `.env` problem on the host (`verify.sh`) |
| `reason=provenance_unavailable` / `images_missing` | Same, then [Flaky TLS](#flaky-tls-random-images_missing-or-provenance_unavailable) | The host could not reach GitHub or GHCR. Re-run the workflow (`gh run rerun <id> --failed`) |
| `reason=provenance_rejected` | The history line | The SHA is not ahead of the running release (an older run). Expected; nothing changed |
| `pull_failed`, `backup_failed`, `migrate_failed` | The journal | Nothing was applied (`.env` untouched); fix and re-run |
| `rolled_back` (`health_failed`, `smoke_failed`, `apply_failed`) | The journal and `docker compose logs <service>` | The previous release is running; fix forward |
| `rollback=failed` | [When `rollback=failed`](#when-rollbackfailed-or-the-stack-is-unhealthy) | Manual attention |

### GitHub settings

Documented with the rest in [`../runner/README.md`](../runner/README.md#github-settings) and
[`../ci/README.md`](../ci/README.md#branch-protection-manual-github-settings-are-not-in-the-repository):

- Environment `production` limited to `main` (applied). **No required reviewers**: deploys are automatic, a decision of
  US-CICD-005. To add a manual gate before each deploy: Settings → Environments → `production` → Required reviewers. Runs then
  wait for approval before the `deploy` job starts, and an unapproved run is cancelled after 30 days.
- Branch protection on `main`: only `ci` is required (applied). `wait-for-ci` makes the deploy depend on `publish` as well.
- If the repository becomes private: a new runner registration token and GHCR pull credentials on the host (see the links above).

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

### Flaky TLS: random `images_missing` or `provenance_unavailable`

Both reasons come from read-only network checks of the host (the GitHub compare API with `curl`, `docker manifest inspect`
against GHCR). `deploy.sh` retries each of them (`DEPLOY_NET_RETRIES`, default 4, `DEPLOY_NET_RETRY_DELAY`, default 2 s), so a
one-off hiccup does not fail a deploy, and they fail closed when the failure persists.

If they fail often although the image exists and the repository is public, measure the link before touching the code:

```bash
for i in 1 2 3 4 5 6 7 8 9 10; do curl -sS -m 12 -o /dev/null https://api.github.com/ || echo failed; done
for i in 1 2 3 4 5 6 7 8 9 10; do curl --curves X25519 -sS -m 12 -o /dev/null https://api.github.com/ || echo failed; done
```

If the first loop fails (`unexpected eof`, `connection reset`) and the second does not, something in the path (a router, the
hypervisor's NAT, a firewall) drops the larger ClientHello that OpenSSL 3.5 and Go 1.24+ send for the post-quantum key
exchange. Set `DEPLOY_TLS_CLASSIC_KEX=1` in the host `.env`: the checks then offer only classic curves
(`curl --curves X25519:secp256r1`, `GODEBUG=tlsmlkem=0` for the Docker CLI). It is off by default because it gives up the
post-quantum hybrid for those requests; the better fix is the network. The Docker daemon (which does the `pull`) was not
affected in the case that motivated this (VirtualBox VM, 10 of 10 pulls fine against 3 of 10 failing `manifest inspect`), and
`tcp_mtu_probing` and IPv4-only made no difference there.

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
| Deploy flow with a fake `docker`/`curl` (success, failed pull, backup, migrate and `up`, failed health gate or smoke test with rollback, first deploy) and the guards (parser, provenance, registry) | `scripts/ci/test_deploy.sh`, CI job `deploy-guards` |
| Post-deploy smoke test (fake `curl`/`docker`, one mutation per check) | `scripts/ci/test_smoke.sh`, `deploy-guards` |
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
| 7 | Smoke test inside a real deploy | automatic deploy of `4538ba4` (below) | six checks `ok` in the journal, gateway on the deployed tag |
| 8 | `rolled_back` with `smoke_failed` | **not reproduced on the VM**: it needs a release that is broken only for itself, i.e. a broken commit published to `main` on purpose, and a flag that breaks the probe breaks the rollback too (row 5) | covered by `test_deploy.sh` (smoke fails → `rolled_back`/`smoke_failed`/`rollback=ok`; both fail → `failed`/`rollback=failed`; mutation "no rollback after `smoke_failed`" turns it red). Optional operator drill: a release that fails only itself, then a revert |

### End-to-end continuous delivery (2026-11-01)

PR #12 (`fix/deploy-network-resilience`) merged at 14:31:14 UTC with no manual command afterwards:

| Step | Run | Time (UTC) |
|---|---|---|
| Merge to `main` (`4538ba4`) | PR #12 | 14:31:14 |
| `CI` (`ci` and `publish`) | [41316601368](https://github.com/Sanchochx/autoOps/actions/runs/41316601368) | 14:31:16 – 14:34:24 |
| `Deploy` / `wait-for-ci` | [41316601384](https://github.com/Sanchochx/autoOps/actions/runs/41316601384) | 14:31:19 – 14:34:27 |
| `Deploy` / `deploy` (request, host deploy, smoke) | same run | 14:34:31 – 14:35:52 |

**Merge to `succeeded`: about 4 min 38 s**, of which about 3 min is the CI and image publication the gate waits for. Journal:
`deploy: health probe ok (attempt 1/12)`, six `ok` lines of the smoke test, `deploy: state=succeeded reason=none rollback=none
tag=4538ba4187d4139bd7f477988b66f5d67c76d9d1`. This was after the PR #10 (noexec workspace), #11 (stderr) and #12 (flaky outbound
TLS, `DEPLOY_TLS_CLASSIC_KEX=1` on this host) fixes; the earlier real runs failed for those environment reasons, not for the
logic. A `workflow_dispatch` of `main` run afterwards ([41316782562](https://github.com/Sanchochx/autoOps/actions/runs/41316782562))
also ended green.
