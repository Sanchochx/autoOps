# US-CICD-002: Build and Publish Images to GHCR

**Epic:** 14 — CI/CD
**Priority:** HIGH
**Estimate:** 5 pts
**Dependencies:** US-CICD-001, US-PROXY-002
**Status:** In progress

---

## User Story

**As** a DevOps engineer,
**I need** every commit that reaches `main` with a green CI to produce container images tagged with its commit SHA in GitHub Container Registry, and the Compose file to consume them by tag,
**so that** the host never builds anything: it only pulls an immutable, traceable image, and development keeps building locally from the same file.

---

## Decisions

- **Four images**, one per `build:` in `docker-compose.yml`: `api-gateway` (also used by `migrate`, which shares its Dockerfile and therefore its image), `frontend`, `mcp-logs` and `traefik`. Names are `${IMAGE_REPOSITORY}/<service>` with `IMAGE_REPOSITORY=ghcr.io/<owner>/autoops` (owner in lowercase, as GHCR requires). Nothing registry-specific is hardcoded in the Compose or the scripts.
- **Immutable tags only.** Each image is tagged with the full commit SHA. There is no `latest` and no moving `main` tag: a deploy names the exact commit it runs, and a rollback is another SHA (US-CICD-004).
- **Compose keeps `build:` and gains `image:`**: `image: ${IMAGE_REPOSITORY:-autoops}/<service>:${IMAGE_TAG:-dev}`. Development (`docker compose up --build`) builds and tags `autoops/<service>:dev`; the host sets `IMAGE_REPOSITORY` and `IMAGE_TAG` and runs `docker compose pull`. A single file serves both worlds.
- **Production never runs the mutable `dev` tag.** `validate_env.sh` rejects `IMAGE_TAG` empty or `dev` when `ENVIRONMENT=production`.
- **Single source of truth for build settings.** The images are built with `docker buildx bake` reading `docker-compose.yml`, so contexts, Dockerfiles and build-args (the `VITE_*` same-origin values, `TRAEFIK_VERSION`) are the ones used locally; CI never re-declares them.
- **Publishing is restricted.** Images are pushed only on `push` to `main`, in a job that `needs: ci` (a red CI publishes nothing). Pull requests build the images without pushing, so a broken Dockerfile is caught before the merge and fork pull requests never get a write token.
- **Least privilege.** `packages: write` is granted to the publishing job only; the workflow default stays `contents: read`. Authentication is the built-in `GITHUB_TOKEN`; no personal access token is stored in the repository.
- **Package visibility follows the repository.** If the packages are private, the host needs a read-only credential (`read:packages`) to pull; how it is provisioned and stored is decided in US-CICD-003/004, not here.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: Align the Dockerfiles with CI and Build Every Image on Pull Requests**
  - `apps/frontend/Dockerfile` builds with Node 22: `ARG NODE_VERSION=22` and `FROM node:${NODE_VERSION}-alpine`. A CI step fails when that default differs from `apps/frontend/.nvmrc`, so the image and the pipeline cannot drift again. The Python images are already 3.11, the version CI tests.
  - New job `images` in `ci.yml`: on pull requests it builds the four images with `docker buildx bake` from `docker-compose.yml`, no push, GitHub Actions cache enabled; it is added to `needs:` of the `ci` gate.
  - **Verification:** locally, `docker compose build` still works and the frontend image reports Node 22 in its build stage; on a pull request the job is green, and breaking a `COPY` path in a Dockerfile turns `images` and `ci` red.

- [ ] **AC-2: Compose Consumes Images by Tag, Development Keeps Building**
  - `docker-compose.yml`: every service that has `build:` also gets `image: ${IMAGE_REPOSITORY:-autoops}/<service>:${IMAGE_TAG:-dev}` (`migrate` uses the `api-gateway` image). `.env.example` documents `IMAGE_REPOSITORY` and `IMAGE_TAG`; `validate_env.sh` enforces the production rule above.
  - The `compose` and `compose-guard` jobs of CICD-001 keep passing unchanged, plus one extra cell with `IMAGE_REPOSITORY=ghcr.io/example/autoops` and a SHA-like `IMAGE_TAG`.
  - **Verification:** `docker compose config` shows the expected image names for the default and for explicit values; `docker compose up -d --build` still starts the stack from a clean checkout; `validate_env.sh` fails with `ENVIRONMENT=production` and `IMAGE_TAG` unset or `dev`, and passes with a SHA.

- [ ] **AC-3: Publish to GHCR from `main` After a Green CI**
  - Job `publish` in `ci.yml`: `needs: ci`, `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`, `permissions: packages: write` (plus `contents: read`), `docker/login-action` to `ghcr.io` with `GITHUB_TOKEN`, then `docker buildx bake --push` with `IMAGE_REPOSITORY=ghcr.io/${{ github.repository_owner }}/autoops` (lowercased) and `IMAGE_TAG=${{ github.sha }}`. Third-party actions pinned by SHA as in CICD-001.
  - The images carry the OCI labels `org.opencontainers.image.source`, `.revision` (the commit SHA) and `.created`, so any image can be traced to its commit.
  - **Verification:** a merge to `main` publishes four packages tagged with the merge commit's SHA; a pull request publishes nothing; a deliberately red CI on `main` (or the job guard) publishes nothing.

- [ ] **AC-4: Verify a Published Image End to End**
  - From another machine (or the VM): `docker login ghcr.io` if the packages are private, then `IMAGE_REPOSITORY=… IMAGE_TAG=<sha> docker compose pull` pulls the four images without building anything, and the stack starts `healthy` from them (`docker compose up -d --no-build`).
  - `docker image inspect` shows `org.opencontainers.image.revision` equal to the commit; the digest of a pulled image equals the one shown in the registry.
  - **Verification:** `docker compose images` lists the GHCR repository and the SHA tag for every service; `scripts/ops/e2e_https.py` (ticket over HTTPS, events over WSS) passes against that stack.

- [ ] **AC-5: Documentation, Evidence and Closing**
  - `infra/ci/README.md` gains an "Images" section: the four names, the SHA-only tag policy, how to run a given commit (`IMAGE_REPOSITORY`/`IMAGE_TAG`), how to find the SHA of a deployed stack, the package-visibility and pull-credential note, and how to update the pinned actions. `.claude/CLAUDE.md` and `README.md` mention the variables.
  - Evidence recorded in `infra/ci/README.md`: URL of the publishing run, the four package URLs and the output of `docker compose images` from AC-4.
  - **Verification:** a reader can run any published commit following only the document; plan updated (Epic 14 at 40%, Phase 5 at 5/8).

---

## Technical Notes

- **Why bake, not `docker/build-push-action` per image:** four near-identical matrix entries would duplicate contexts and build-args that already live in the Compose, and the two copies would drift. Bake reads the Compose and adds cache and `--push`.
- **Why no `latest`:** a moving tag defeats rollback and makes "what is running?" unanswerable; the deploy flow (CICD-004) validates tags against a strict SHA pattern.
- **Cache:** GitHub Actions cache (`type=gha`) for layers; first run is cold, later runs reuse dependency layers.
- **`migrate` and the tools profile:** it shares the gateway image, so migrations always run with the same code that serves requests.
- **Out of scope:** the self-hosted runner (US-CICD-003), pulling and rolling out on the host (US-CICD-004/005), image signing (cosign), SBOM and vulnerability scanning, retention of old tags/untagged layers, multi-arch images.
