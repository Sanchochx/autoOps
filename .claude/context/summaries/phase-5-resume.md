# Phase 5 Summary: Secure Exposure and CI/CD

**Project:** AutoOps — Self-Hosted Multi-Agent SRE Platform
**Closing date:** 2026-11-01
**Status:** Completed (8/8 US)

| US | Epic | Delivered by |
|----|------|--------------|
| US-PROXY-001 Traefik as the single entry point | 13 | direct commits to `main` |
| US-PROXY-002 TLS: local CA, self-signed and Let's Encrypt HTTP-01 | 13 | direct commits to `main` |
| US-PROXY-003 Close the perimeter | 13 | direct commits to `main` (`8e4d265`) |
| US-CICD-001 CI pipeline | 14 | PR #1 |
| US-CICD-002 Build and publish images to GHCR | 14 | PR #2, #3 |
| US-CICD-003 Containerized self-hosted runner | 14 | PR #4, #5 |
| US-CICD-004 Pull-based deployment on the host | 14 | PR #6, #7 |
| US-CICD-005 CD workflow, smoke test and phase closing | 14 | PR #8, #9, #10, #11, #12 and the closing docs PR |

---

## 📝 Changes Made

- **Single entry point:** Traefik (file provider, no `docker.sock`) is the only container publishing host ports (80 redirects to 443). The gateway and frontend are reachable only through it (`/api`, `/ws` → gateway; `/` → frontend). UFW and `DOCKER-USER` open only the web ports.
- **TLS:** `TLS_MODE` (no default) selects a local CA with a self-signed leaf generated at provisioning (`selfsigned`) or Let's Encrypt HTTP-01 (`acme`). The CA key never reaches the proxy. HSTS is always set.
- **CI:** `ci.yml` on GitHub-hosted runners (pytest offline, frontend lint/typecheck/build, Compose config for every `TLS_MODE`, shellcheck, image builds, runner and workflow guards, deploy tests). `ci` is the only required status.
- **Images:** a green push to `main` publishes the four images to GHCR tagged with the commit SHA; Compose consumes `IMAGE_REPOSITORY`/`IMAGE_TAG`, production rejects `dev`.
- **Runner:** a containerized self-hosted runner (`autoops-prod`), outbound only, read-only root, no Docker socket, no shared network with the stack, only two host mounts (deploy inbox rw, outbox ro). Only `workflow_dispatch` and push-to-`main` workflows with `environment: production` may use it.
- **Pull-based deploy:** the runner leaves a 2-key request; `autoops-deploy.path/.service` on the host validates it (strict parser, provenance through the public compare API), checks and pulls the images, backs up and migrates, applies, probes, and rolls back on failure. The answer is a `status` file of fixed codes.
- **Continuous delivery:** `deploy.yml` (`wait-for-ci` on GitHub, `deploy` on the runner) turns "merge to `main`" into a deployed, smoke-tested release. `scripts/ops/smoke_test.sh` checks the stack over HTTPS from the host and a failure triggers the rollback.
- **Resilience of the host network:** read-only network checks of `deploy.sh` retry (`DEPLOY_NET_RETRIES`); `DEPLOY_TLS_CLASSIC_KEX=1` (off by default) offers only classic curves when something on the path drops the post-quantum ClientHello.

## 📂 Files Modified/Created

| Path | Purpose |
|---|---|
| `infra/traefik/`, `docker-compose.yml` | Reverse proxy, TLS modes, network isolation |
| `.github/workflows/ci.yml` | CI, images, publish, guards |
| `.github/workflows/deploy.yml` | CD: gate on CI, request to the host, job summary |
| `.github/workflows/runner-smoke.yml` | Manual isolation check of the runner |
| `infra/runner/` | Runner image, Compose, docs, GitHub settings |
| `infra/deploy/README.md` | Flow, request/status formats, threat model, CD section, what to do on each red, evidence |
| `scripts/ops/deploy.sh` | Host-side deploy: parse, provenance, pull, backup, migrate, apply, probe, smoke, rollback |
| `scripts/ops/smoke_test.sh` | Post-deploy HTTPS smoke test |
| `scripts/ci/request_deploy.sh` | Runner side: write the request, read the answer, map to exit codes |
| `scripts/ci/check_runner_*.sh`, `test_*.sh` | Guards and tests run in the `deploy-guards`, `runner-compose` and `runner-workflows` jobs |
| `scripts/provision/75_runner.sh`, `checks/75_runner.sh`, `checks/85_deploy.sh` | Provisioning and verification of the runner and deploy units |
| `infra/systemd/autoops-deploy.{path,service}.tpl` | Units that apply a request |

## 🎯 Rationale

- **GitHub cannot reach a host behind NAT, and a runner with Docker access is root-equivalent.** So the runner never touches Docker: it leaves a request and the host re-derives everything from public data and applies it itself. The SSH deploy key of Phase 4 is not used by this flow.
- **The smoke test runs on the host,** because the runner cannot reach the stack by design and a hosted runner would need a hole this project closed on purpose.
- **Wait, do not repeat:** `deploy.yml` starts on the same push and polls the CI run (`workflow_run` is not allowed for runner workflows), so a red CI never reaches the host.
- **Automatic deploys, no required reviewer;** a reviewer on `production` is documented as an optional switch.
- **Roll back images, not schema:** migrations are not reverted, so schema changes must be expand/contract.

## ✅ Evidence

- **End to end (2026-11-01):** PR #12 merged at 14:31:14 UTC; the push-triggered `Deploy` run ([41316601384](https://github.com/Sanchochx/autoOps/actions/runs/41316601384)) finished green at 14:35:52 UTC: **about 4 min 38 s from merge to `succeeded`**, with no manual command. Journal: `deploy: state=succeeded reason=none rollback=none tag=4538ba4…` and six smoke-test `ok` lines.
- **Host verification:** `sudo ./scripts/provision/verify.sh --env-file provision.env` on the VM, 12 groups. See Known Gaps for what failed first and how it was resolved.

## 🔎 Findings During Validation

- The first real deploys failed for environment reasons, not logic: the runner workspace is a `noexec` tmpfs (fixed by `bash scripts/ci/request_deploy.sh`, PR #10); `exec … 2>/dev/null` in `parse_request` silenced all of `deploy.sh`'s stderr (PR #11); outbound TLS from the VM failed about half of the time (`unexpected eof`) with OpenSSL 3.5 and the Go 1.24+ Docker CLI, fixed by retries and the opt-in classic key exchange (PR #12). MTU, IPv4-only and `tcp_mtu_probing` were ruled out.
- `checks/85_deploy.sh` (US-CICD-004) had never passed its functional checks on this VM: it read `PathExists`, which systemd 259 (Ubuntu 26.04) reports as `Paths`, and used `sudo -u "#10001"`, which fails because that UID exists only inside the runner container (and could not traverse `/opt/autoops` anyway). Two "cannot" checks passed vacuously. The runner-side probes now run with `docker exec` in the runner container and are skipped when it is not running.
- The VM had drifted from the Phase 4 baseline: `chrony` inactive and the clock about 9 s off, timezone `America/Bogota`, and `fs.suid_dumpable=2` set by `apport`. `apport` was added to the default `DISABLE_SERVICES` of `50_os_baseline.sh`. The step was re-applied.
- `50_os_baseline.sh` applies `sysctl --system` only when the sysctl file changed, so a value overridden later at runtime (as `apport` did) is not restored by a re-run until `sysctl --system` is run by hand.

## ⚠️ Known Gaps

- **`rolled_back` was not reproduced on the VM.** A release that is broken only for itself would need a broken commit published to `main` on purpose, and a flag that breaks the probe breaks the rollback too. The path is covered by `scripts/ci/test_deploy.sh` (fake `docker`/`curl`, with mutations of `deploy.sh`) and documented in `infra/deploy/README.md`.
- Two items of the runner evidence stay pending (`infra/runner/README.md`): a dispatch from a non-`main` branch being refused, and a fork pull request not reaching the runner without approval.
- The runner is not ephemeral (accepted trade-off; revisit with a GitHub App).
- The images are public GHCR packages; if the repository becomes private the host needs `docker login ghcr.io` and the runner a new registration.
- No notifications (Slack, email), no image signing or attestations, no blue/green or canary.

## 🚀 Next Steps

Phases 1–5 complete the planned platform: agents, persistence, containers, hardened host, reverse proxy with TLS and continuous delivery. Candidates for a next phase, none written yet:

- Notifications for deploy results and a real `rolled_back` drill in a staging copy.
- Ephemeral runner or GitHub App, image signing and provenance attestation.
- A public domain with `TLS_MODE=acme` (needs a public IP) and an off-host copy of the backups.
- Observability for the platform itself (metrics, alerts), which is also the data the Investigator agent would query.
