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
| Infrastructure (Phase 2) | Docker Compose, Traefik/Nginx + Let's Encrypt, GitHub Actions |

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
│   └── ops/             # Operational scripts (PostgreSQL backup and restore, env validation)
├── infra/               # Host configuration templates and docs (SSH, UFW, Docker, systemd, backups, CI)
├── .claude/
│   ├── CLAUDE.md        # Project architecture and standards
│   └── context/         # SDD documentation (plan, user stories, summaries)
├── .env.example         # Centralized environment variable template
├── .gitignore
└── README.md
```

## Prerequisites

- Python 3.11+
- Node.js (LTS) and npm
- PostgreSQL
- Docker and Docker Compose (Phase 2 onwards)

## Getting started

```bash
git clone <repository-url> autoops
cd autoops
cp .env.example .env    # and edit the values
```

Run commands become available after the corresponding user stories:

- **Backend / API Gateway:** available after US-GW-001.
- **Frontend:** available after US-FE-001.
- **Containers:** available in Phase 2.

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
