# AutoOps

Self-hosted multi-agent SRE platform. It is an autonomous technical support system (Tier-1) that receives and classifies incident tickets, investigates the root cause by querying logs, metrics and databases through isolated Model Context Protocol (MCP) servers, and proposes automatic or human-supervised remediation plans (Human-in-the-Loop, HITL).

Three agents orchestrated with LangGraph:

1. **Triage:** classifies severity and routes the ticket.
2. **Investigator:** inspects logs and metrics through MCP tools.
3. **Executor:** generates mitigation plans and manages HITL approvals.

## Tech stack

| Layer | Technology |
|------|------------|
| Backend / API Gateway | Python 3.11+, FastAPI, Pydantic, WebSockets + REST |
| AI engine | LangGraph + LangChain, MCP SDK |
| Persistence | PostgreSQL, SQLAlchemy, Alembic |
| Frontend | React + Vite + TypeScript, TailwindCSS, Zustand |
| Infrastructure | Docker Compose, Traefik/Nginx + Let's Encrypt, GitHub Actions |

## Monorepo structure

```
autoops/
├── apps/
│   ├── frontend/        # Admin dashboard (React + Vite + TypeScript + TailwindCSS)
│   └── api_gateway/     # FastAPI: REST, WebSockets and authentication
├── services/
│   ├── ai-engine/       # LangGraph agents (Triage, Investigator, Executor)
│   └── mcp-servers/     # MCP servers (DB, logs and metrics isolation)
├── scripts/
│   ├── provision/       # Idempotent host bootstrap (bootstrap.sh), verify.sh and per-control checks
│   ├── ops/             # Operational scripts (PostgreSQL backup and restore, env validation)
│   └── ci/              # Guards run by CI (self-hosted runner lock-down and allowed workflows)
├── infra/               # Host configuration templates and docs (SSH, UFW, Docker, systemd, backups, CI, self-hosted runner)
├── .claude/
│   ├── CLAUDE.md        # Project architecture and standards
│   └── context/         # SDD documentation (plan, user stories, summaries)
├── .env.example         # Centralized environment variable template
├── .gitignore
└── README.md
```

## Prerequisites

**AutoOps runs on Linux only**, with Docker Compose (tested on Ubuntu Server, on bare metal or in a VM).

- Docker Engine with the Compose plugin
- `git`, `openssl`, `curl` and `sudo` (the TLS script needs root)
- An LLM API key (`OPENAI_API_KEY`; the AI engine uses `ChatOpenAI`, optionally against another OpenAI-compatible
  endpoint through `OPENAI_BASE_URL`)
- To run the tests from the host: Python 3.11+ and Node.js 22 (see `apps/frontend/.nvmrc`)

> **Windows and macOS are not supported.** The provisioning and operations scripts are Bash, and the TLS script
> needs root on Linux.

## Quickstart (Docker Compose behind Traefik, HTTPS)

```bash
# 1. Get the code and the configuration
git clone https://github.com/Sanchochx/autoOps.git autoops && cd autoops
cp .env.example .env
```

```bash
# 2. Edit .env. At least: DB_PASSWORD, SECRET_KEY, OPENAI_API_KEY, AI_MODEL_NAME (e.g. gpt-4o-mini),
#    DOMAIN (default autoops.local), TLS_MODE=selfsigned, PUBLIC_SCHEME=https
#    DATABASE_URL in .env.example is only for host-side tools; Compose builds its own from DB_*.
```

```bash
# 3. Local certificate authority + server certificate (TLS_MODE=selfsigned). Writes ./tls
sudo APP_DIR="$PWD" TLS_DIR="$PWD/tls" ./scripts/provision/65_tls.sh
```

```bash
# 4. Start the stack and apply the database migrations (`up` does NOT migrate)
docker compose up -d --build --wait
docker compose --profile tools run --rm migrate
```

```bash
# 5. Make the domain resolve and trust the local CA (on the machine that runs the browser)
echo "127.0.0.1 autoops.local" | sudo tee -a /etc/hosts        # use the VM's IP if the browser is elsewhere
sudo cp tls/ca/ca.crt /usr/local/share/ca-certificates/autoops-local-ca.crt && sudo update-ca-certificates
# Firefox keeps its own store; see infra/traefik/README.md ("Trusting the local CA").
```

Open `https://autoops.local`: create a ticket and watch the agents in the console. It goes **Abierto → Investigando →
Escalado**, with the Investigator's analysis in the table (persisted in the database, so it survives a reload).
If the AI call fails, the ticket returns to **Abierto** and the console shows the error; check
`docker compose logs api-gateway`.

### Verify it works

```bash
source venv/bin/activate && pip install -r apps/api_gateway/requirements-dev.txt -r services/ai-engine/requirements.txt
pytest tests -v                                                      # backend tests (no network, no DB)
(cd apps/frontend && npm ci && npm test && npm run lint && npm run build)

# Post-deploy checks through HTTPS (run from the repository root, one line each)
SMOKE_DOMAIN=autoops.local SMOKE_HTTPS_PORT=443 SMOKE_HEALTH_PATH=/api/v1/tickets SMOKE_CACERT=tls/ca/ca.crt scripts/ops/smoke_test.sh
E2E_CONNECT_ADDR=127.0.0.1 python scripts/ops/e2e_https.py --ca tls/ca/ca.crt
```

### Current limitations

- The MCP logs server (`services/mcp-servers/logs_server`) serves **simulated** data, and the Investigator does **not**
  query it yet: its analysis is based only on the text of the ticket. Paste real logs and stack traces into the description.
- There is no Executor agent or approval flow (HITL) yet: a successfully investigated ticket is `escalated` to a human;
  `pending_approval` and `resolved` are not used by the agents.
- The REST API has no authentication yet (`DELETE /api/v1/tickets` removes every ticket).

### Run published images (no local build)

CI publishes the images to GHCR from `main`, tagged with the commit SHA. To run a given commit:

```bash
export IMAGE_REPOSITORY=ghcr.io/<owner>/autoops IMAGE_TAG=<full commit SHA>   # also settable in .env
docker compose pull && docker compose up -d --no-build
```

Without those variables `docker compose up -d --build` builds locally and tags `autoops/<service>:dev`. See
[`infra/ci/README.md`](infra/ci/README.md#images-us-cicd-002).

### Database migrations (Alembic, from the monorepo root)

```bash
alembic -c apps/api_gateway/alembic.ini upgrade head     # apply migrations
# Under Docker Compose `up` does NOT migrate; run: docker compose --profile tools run --rm migrate
alembic -c apps/api_gateway/alembic.ini current          # current revision
alembic -c apps/api_gateway/alembic.ini revision --autogenerate -m "description"
```

Requires `DATABASE_URL` (`postgresql+asyncpg://...`) in `.env`.

### Host provisioning (Ubuntu Server 26.04)

```bash
sudo ./scripts/provision/bootstrap.sh --env-file provision.env   # idempotent
sudo ./scripts/provision/verify.sh --env-file provision.env      # OK/FAIL table, exit 1 on any failure
```

See [`infra/README.md`](infra/README.md) for the full cycle (variables, SSH confirmation, reboot test).

### Self-hosted runner (optional, for continuous deployment)

With `RUNNER_REPO_URL` set in `.env`, `bootstrap.sh` also installs a containerized GitHub Actions runner
(`autoops-runner.service`, label `autoops-prod`): outbound connections only, no Docker socket, no access to the stack's
networks, and usable only by `workflow_dispatch` / push-to-`main` workflows. See
[`infra/runner/README.md`](infra/runner/README.md). The runner never touches Docker: it leaves a deploy request that the host
validates and applies itself, with automatic rollback, see [`infra/deploy/README.md`](infra/deploy/README.md).

### Continuous delivery

A push to `main` with a green CI is deployed automatically (`.github/workflows/deploy.yml`): the workflow waits for the CI and
the published images, asks the host through the runner, and the host applies the release, runs a smoke test over HTTPS and rolls
back if it fails. See [`infra/deploy/README.md`](infra/deploy/README.md#continuous-delivery-us-cicd-005).

The definitive commands are documented in [`.claude/CLAUDE.md`](.claude/CLAUDE.md#key-commands).

## Key principles

- **Twelve-Factor (zero hardcoding):** credentials, keys, URLs and ports are always read from environment variables (`.env`).
- **MCP isolation:** the AI engine never connects directly to PostgreSQL nor runs system commands; all infrastructure interaction goes through authorized MCP servers.
- **Cloud-native logging:** all services emit logs to stdout/stderr; no local files are written or rotated.

## Workflow (SDD)

The project follows Spec-Driven Development: one user story at a time, acceptance criteria one by one, and a mandatory checkpoint before moving on.

- [Implementation plan](.claude/context/IMPLEMENTATION_PLAN.md)
- [Task execution workflow](.claude/context/TASK_EXECUTION.md)
- [Architecture and standards guide](.claude/CLAUDE.md)

### Branches

| Branch | Purpose |
|------|-----------|
| `main` | Production / deployment-ready code |
| `develop` | Feature integration |
| `feature/descriptive-name` | New features |
| `fix/bug-name` | Bug fixes |

```text
+============================================================================+
   _____                  __               ____           
  / ___/____ _____  _____/ /_  ____       / __ \___ _   __
  \__ \/ __ `/ __ \/ ___/ __ \/ __ \     / / / / _ \ | / /
 ___/ / /_/ / / / / /__/ / / / /_/ /    / /_/ /  __/ |/ / 
/____/\__,_/_/ /_/\___/_/ /_/\____/____/_____/\___/|___/  
                                 /_____/                  

               .-"""-.
             _/-=-.   \
            (_|a a/   |_
             / "  \   ,_)
        _    \`=' /__/
       / \_  .;--'  `-.
       \___)//      ,  \
        \ \/;        \  \
         \_.|         | |
          .-\ '     _/_/
        .'  _;.    (_  \
       /  .'   `\   \\_/
      |_ /       |  |\\
     /  _)       /  / ||
    /  /       _/  /  //
    \_/       ( `-/  ||
              /  /   \\ .-.
              \_/     \'-'/
                       `"`
+============================================================================+

> _
