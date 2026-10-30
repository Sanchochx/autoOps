# 🚀 AutoOps - Self-Hosted Multi-Agent SRE Platform

## Description
**AutoOps** is an autonomous technical support system (Tier-1) designed for companies. It is built as microservices and orchestrated by AI agents using LangGraph. The system receives and classifies incident tickets, investigates the root cause by querying infrastructure, logs and databases through isolated Model Context Protocol (MCP) servers, and proposes automatic or human-supervised remediation plans (Human-in-the-Loop).

---

## Tech Stack

### Backend & API Gateway
- **Framework:** Python 3.11+ / FastAPI
- **Communication:** WebSockets (real-time streaming of agent reasoning) and REST (CRUD operations, tickets and authentication)
- **Data validation:** Pydantic (strict typing)

### AI Engine & Tools
- **Agent orchestration:** Python / LangGraph + LangChain
- **Tool isolation:** Model Context Protocol (MCP SDK)
- **Agents:**
  1. *Triage:* severity classification and ticket routing.
  2. *Investigator:* log and metric inspection via MCP tools.
  3. *Executor:* mitigation plan generation and HITL approval management.

### Database & Persistence
- **Database:** PostgreSQL
- **ORM / Migrations:** SQLAlchemy / Alembic

### Frontend
- **Framework:** React + Vite + TypeScript
- **Styling:** TailwindCSS
- **State management:** Zustand / React Context (WebSockets and UI state)

### Infrastructure & DevOps
- **Containers:** Docker & Docker Compose
- **Reverse proxy:** Traefik / Nginx with SSL termination (Let's Encrypt)
- **Deployment OS:** Ubuntu Server (AWS EC2 / local VirtualBox VM)
- **CI/CD:** GitHub Actions (CI: `.github/workflows/ci.yml`, see `infra/ci/README.md`; images published to GHCR from `main`, tagged with the commit SHA; a containerized self-hosted runner on the host, see `infra/runner/README.md`; automatic deployment over SSH)

---

## Key Commands

### Backend & AI Engine (Python / FastAPI)
```bash
# Activate virtual environment
source venv/bin/activate        # Linux/Mac
venv\Scripts\activate           # Windows

# Install dependencies
pip install -r requirements.txt

# Run the API Gateway in development
uvicorn apps.api_gateway.main:app --reload --port 8000

# Run unit and integration tests
pytest tests/ -v
pytest tests/ -v --cov=services
```

### Frontend (React / Vite)
```bash
# Change to the frontend directory
cd apps/frontend

# Install dependencies
npm install

# Run in development
npm run dev

# Build for production
npm run build
```

### Host provisioning (Phase 4, Ubuntu Server 26.04)
```bash
sudo ./scripts/provision/bootstrap.sh --env-file provision.env   # idempotent bootstrap
sudo ./scripts/provision/verify.sh --env-file provision.env      # verify all controls (exit 1 on failure)

# Optional self-hosted runner (US-CICD-003): runs only when RUNNER_REPO_URL is set in .env; see infra/runner/README.md
#   RUNNER_REGISTRATION_TOKEN_FILE=<token file> sudo ./scripts/provision/75_runner.sh
# Guards run by CI (GitHub-hosted): scripts/ci/check_runner_compose.sh, scripts/ci/check_runner_workflows.sh
```

### Docker Orchestration (Phase 2+)
```bash
# Start all services in the background
docker compose up -d --build

# Only Traefik publishes host ports (https://$DOMAIN:$PROXY_HTTPS_PORT; $PROXY_HTTP_PORT redirects to it); the gateway and frontend
# are reachable only through it (/api, /ws -> gateway; / -> frontend). See infra/traefik/README.md

# On a host: run a published commit instead of building (see infra/ci/README.md)
#   IMAGE_REPOSITORY=ghcr.io/<owner>/autoops IMAGE_TAG=<sha> docker compose pull && docker compose up -d --no-build

# Follow unified logs
docker compose logs -f

# Stop the container ecosystem
docker compose down
```

---

## Monorepo Structure

```
autoops/
├── apps/
│   ├── frontend/             # React + Vite + TypeScript + TailwindCSS (Admin dashboard)
│   └── api_gateway/          # FastAPI (REST, WebSockets, Auth) — underscore for Python imports
├── services/
│   ├── ai-engine/            # LangGraph (Triage, Investigator and Executor agents)
│   └── mcp-servers/          # MCP servers (DB, logs and metrics isolation)
├── scripts/
│   ├── provision/            # bootstrap.sh, verify.sh, NN_*.sh steps and checks/ (idempotent host setup)
│   ├── ops/                  # Backup/restore PostgreSQL, env validation
│   └── ci/                   # Guards run by CI (runner Compose lock-down, workflows allowed to use the runner)
├── infra/                    # Host config templates and docs (ssh, fail2ban, firewall, docker, systemd, backup, ci, runner) and the Traefik reverse proxy (Dockerfile, static + dynamic config)
├── .claude/
│   ├── CLAUDE.md             # This file (architecture and standards guide)
│   └── context/              # SDD documentation and tracking
│       ├── user_stories/         # User stories ordered by epic
│       ├── summaries/            # Executive summaries at the end of each phase
│       ├── IMPLEMENTATION_PLAN.md# Master plan of user stories and progress
│       └── TASK_EXECUTION.md     # Instruction manual for Claude Code
├── .env.example              # Centralized environment variable template
└── docker-compose.yml        # Container orchestration and private networks (Phase 2)
```

---

## Code Conventions

### Language
- **All documentation, comments, docstrings and identifiers are written in English** (README, CLAUDE.md, user stories, plans, summaries, skills).

### Naming
- Python: `snake_case` for functions, methods, variables and files (`ticket_service.py`).
- TypeScript / React: `camelCase` for variables and functions; `PascalCase` for Components and Interfaces (`TicketCard.tsx`).
- Classes: `PascalCase` in both languages.
- Constants: `UPPER_SNAKE_CASE`.
- REST API routes: `/kebab-case` (e.g. `/api/v1/tickets/active-alerts`).

### Branches
- `main` → Production / deployment-ready code
- `develop` → Feature integration
- `feature/descriptive-name`
- `fix/bug-name`

---

## Important Rules and DevOps Principles

1. **The Twelve-Factor App (zero hardcoding):**
   - NEVER write credentials, API keys, URLs or ports directly in code.
   - Every configurable parameter is read from environment variables (`.env`).

2. **Strict isolation through MCP (sandboxing):**
   - The AI engine (LangGraph) NEVER connects directly to PostgreSQL nor runs operating system commands.
   - All infrastructure interaction must go through the authorized MCP servers.

3. **Cloud-native logging strategy:**
   - All microservices must emit their logs to stdout and stderr.
   - Do not use libraries that write or rotate local text files inside the application.

4. **Spec-Driven Development (SDD):**
   - Claude Code must strictly follow the workflow described in @context/TASK_EXECUTION.md.
   - Develop the Acceptance Criteria ONE AT A TIME.
   - Make a mandatory pause at Checkpoints before marking a User Story as completed.

---

## Required Environment Variables (.env)

```bash
# Server & Gateway
PORT=8000
DEBUG=True
ENVIRONMENT=development
SECRET_KEY=autoops_jwt_secret_key

# PostgreSQL Database
DB_HOST=localhost
DB_PORT=5432
DB_NAME=autoops_db
DB_USER=autoops_user
DB_PASSWORD=autoops_password

# AI Models & Telemetry
OPENAI_API_KEY=your_openai_key
ANTHROPIC_API_KEY=your_anthropic_key
LANGCHAIN_TRACING_V2=true
LANGCHAIN_API_KEY=your_langsmith_key

# MCP Servers
MCP_LOGS_SERVER_URL=http://localhost:5001
MCP_DB_SERVER_URL=http://localhost:5002

# Frontend (Vite) — development values; under Docker Compose the frontend is built with same-origin paths
VITE_API_BASE_URL=http://localhost:8000
VITE_WS_BASE_URL=ws://localhost:8000/ws

# Reverse proxy (Traefik)
DOMAIN=autoops.local      # required; the only Host Traefik routes
PUBLIC_SCHEME=https       # http | https; forms the CORS origin with DOMAIN (https required for TLS_MODE=acme)
PROXY_HTTP_PORT=80        # only redirects to HTTPS
PROXY_HTTPS_PORT=443
TLS_MODE=selfsigned       # required: selfsigned (local CA) | acme (Let's Encrypt HTTP-01); needs ACME_EMAIL
HSTS_MAX_AGE_SECONDS=31536000

# Container images (optional; defaults build locally as autoops/<service>:dev)
IMAGE_REPOSITORY=ghcr.io/<owner>/autoops   # host: published images; owner in lowercase
IMAGE_TAG=<commit SHA>                     # immutable tag; `dev` or empty is rejected when ENVIRONMENT=production
```

---

## Frontend Standards

### Philosophy
Every UI must be production-grade: accessible, performant, maintainable and intentional. The code must be able to pass a strict code review.

### Component Architecture
- **Separation of concerns:** business logic lives outside the UI component.
  - Custom Hooks for logic and HTTP/WebSocket calls; components dedicated solely to rendering.
- **Small, focused components:** maximum ~150 lines per file, a single responsibility.
- **Strict typing:** TypeScript in strict mode, no use of `any`.
- **Feature-based structure:**
  ```
  feature/
  ├── components/     ← pure UI (no API calls)
  ├── services/       ← HTTP and WebSocket client
  ├── models/         ← interfaces and types
  ├── hooks/          ← state and business logic
  └── index.ts        ← barrel export
  ```

### TypeScript
- `strict: true` enabled in `tsconfig.json`.
- Interfaces for domain objects (`Ticket`, `AgentState`), types for unions and utilities.
- Use `unknown` + type guards instead of `any`.
- Explicitly type function return values and event handlers.

### Styles and Design
- Use TailwindCSS classes, staying consistent with the dashboard design.
- Dynamic layouts with CSS Grid for the main dashboard views and Flexbox for linear components.
- Mobile-first approach using Tailwind breakpoints (`md:`, `lg:`).

### Accessibility (a11y) — Non-negotiable
- Interactive elements operable via keyboard (Tab, Enter, Space).
- Explicit `<label>` for all data input fields.
- Color contrast ratio compliant with WCAG AA (4.5:1 for normal text).
- ARIA attributes and roles for HITL approval modals and dynamic ticket tables.
- Clear visual styles for `:focus-visible`.

### Performance
- Lazy loading of secondary views with `React.lazy` and `Suspense`.
- Re-render optimization in components bound to WebSocket streaming.
- Predictable, immutable state management using Zustand.
