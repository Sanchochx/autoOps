# Continuous integration (US-CICD-001)

`.github/workflows/ci.yml` runs on every pull request to `develop` or `main` and on every push to those branches,
on GitHub-hosted runners. It **validates**; it never builds images, publishes anything or deploys (that is
US-CICD-002 and later), and it needs **no secrets**: `permissions: contents: read`, no `pull_request_target`.

## Jobs

| Job | What it checks | Reproduce locally |
|---|---|---|
| `backend` | `pytest tests/ -v` on Python 3.11, from a clean checkout: no `.env`, no LLM key, and `.github/ci/nonet/sitecustomize.py` makes any non-loopback connection fail | `python3.11 -m venv v && v/bin/pip install -r apps/api_gateway/requirements-dev.txt -r services/ai-engine/requirements.txt -r services/mcp-servers/logs_server/requirements.txt && PYTHONPATH=.github/ci/nonet v/bin/pytest tests/ -v` (run it from an export without `.env`: `git archive HEAD \| tar -x -C /tmp/x`) |
| `frontend` | `npm ci`, `lint`, `typecheck` (`tsc -b`), `build`, with the Node version in `apps/frontend/.nvmrc` | `cd apps/frontend && npm ci && npm run lint && npm run typecheck && VITE_API_BASE_URL=/ VITE_WS_BASE_URL=/ws npm run build` |
| `compose` (4 cells) | `docker compose config -q` for `TLS_MODE` ∈ {`selfsigned`, `acme`} × {base, base + `docker-compose.dev-db.yml`} using `.env.example` | `cp .env.example .env && docker compose config -q` (for `acme` also set `ACME_EMAIL` and `PUBLIC_SCHEME=https`) |
| `compose-guard` | Without `TLS_MODE` the Compose must be rejected, and the error must name `TLS_MODE` | `sed '/^TLS_MODE=/d' .env.example > .env && docker compose config -q` (must fail) |
| `shellcheck` | Every tracked `*.sh`, severity `warning`, config in `.shellcheckrc` | `git ls-files -z '*.sh' \| xargs -0 shellcheck --severity=warning` |
| `ci` | Aggregate gate: passes only if every job above succeeded (also when one failed, was cancelled or skipped) | — |

## Design rules

- **Third-party actions are pinned by full commit SHA**, with the version in a comment. To update one, resolve the tag
  again (`git ls-remote --tags https://github.com/<owner>/<action> 'refs/tags/v*'`; for an annotated tag use the
  `^{}` line) and change SHA and comment together. Never use a moving tag.
- **`ci` is the only status branch protection requires.** To add a job, add it to `needs:` of `ci`; renaming or
  adding jobs then never breaks the protection rule.
- **Concurrency:** a new push to a pull request cancels its running workflow; runs on `develop` and `main` are never
  cancelled.
- **Versions match what ships:** Python 3.11 (the Dockerfiles), Node from `.nvmrc`. Known drift:
  `apps/frontend/Dockerfile` still builds with `node:20-alpine` (planned for US-CICD-002).
- The `.env` that the `compose` jobs create comes from `.env.example`; its placeholders would be rejected by
  `scripts/ops/validate_env.sh` in production, which is intended: CI never runs a production configuration.

## Branch protection (manual: GitHub settings are not in the repository)

GitHub → Settings → Branches → add a rule for `main` (and for `develop` once it exists):

- Require a pull request before merging. Required approvals: 0 while there is a single maintainer; raise it with the team.
- Require status checks to pass before merging → select **`ci`** only. Require branches to be up to date before merging.
- Block force pushes and deletions. Optionally apply the rules to administrators.

Check the result:

```bash
gh api repos/Sanchochx/autoOps/branches/main/protection \
  --jq '{checks: .required_status_checks.contexts, strict: .required_status_checks.strict, force_push: .allow_force_pushes.enabled}'
# expected: {"checks":["ci"],"strict":true,"force_push":false}
```

A pull request whose `ci` is red cannot be merged once the rule is on.

## Evidence

Rows marked _pending_ were not supplied when the story was closed; fill them in from the Actions tab (no URL has been
invented here).

| Case | Run |
|---|---|
| Green run (all jobs, `ci` green) | _pending: add the run URL_ |
| Red run on purpose (e.g. a broken test; `backend` and `ci` red) | _pending: add the run URL_ |
| Merge blocked by a red `ci` | _pending: add the pull request URL_ |
| Branch protection on `main` (`gh api …/protection`) | Reported by the maintainer: required status checks = `["ci"]`. `strict` and `allow_force_pushes` values were not reported |

## Images (US-CICD-002)

_Work in progress: AC-4 (end-to-end pull on another machine) and AC-5 (usage guide) complete this section._

### Evidence: publication (AC-1, AC-3)

| Case | Evidence |
|---|---|
| `images` red on a broken `COPY` (pull request, `images` and `ci` red) | https://github.com/Sanchochx/autoOps/actions/runs/40793389105 |
| `images` green again after the revert | https://github.com/Sanchochx/autoOps/actions/runs/40793775201 |
| Publication on `main` (all jobs green, `publish` pushed four images) | https://github.com/Sanchochx/autoOps/actions/runs/40796026748 |
| `publish` skipped on a pull request | https://github.com/Sanchochx/autoOps/pull/2 |

Merge commit `6117b7aac20113f25ad4e8ba8dd8f586e2f787ce`, published as that exact tag (index digests):

| Package | Digest |
|---|---|
| https://github.com/users/Sanchochx/packages/container/package/autoops%2Fapi-gateway | `sha256:0b75ba6b4721805ac1e33b2713d91ab259f8bb8bf38307452fd2348f3db620cf` |
| https://github.com/users/Sanchochx/packages/container/package/autoops%2Ffrontend | `sha256:66387f878305848848e6e9c51eac458d1a3f576501574a74c922d3874599dd5d` |
| https://github.com/users/Sanchochx/packages/container/package/autoops%2Fmcp-logs | `sha256:71f114dbde03c8091e688afbcbd674c7018278a8f84609249b35fab9afb8e1d6` |
| https://github.com/users/Sanchochx/packages/container/package/autoops%2Ftraefik | `sha256:bdeff3714e99f1ccd4264f0a7777f011ac2bf43505d2c158869c2a9c5f897c38` |

The digests are the ones in the `publish` log; the registry reports the same ones for the tagged versions. All four
packages are `public` (they inherit the visibility of the repository) and carry, in the image config read from the
registry, `org.opencontainers.image.revision` = the commit above, `.source` = https://github.com/Sanchochx/autoOps and
`.created` = `2026-10-29T00:45:45Z` (`traefik` also keeps the upstream labels).

## Out of scope

Image build and publication (US-CICD-002), self-hosted runner (US-CICD-003), deployment (US-CICD-004/005), coverage
thresholds, dependency and image vulnerability scanning.
