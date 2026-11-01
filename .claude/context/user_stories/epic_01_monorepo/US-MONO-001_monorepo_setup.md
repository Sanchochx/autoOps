# US-MONO-001: Monorepo Setup

**Epic:** 01 — Monorepo & Base Setup
**Priority:** CRITICAL
**Estimate:** 3 pts
**Dependencies:** None
**Status:** Completed

---

## User Story

**As** a developer on the AutoOps team,
**I want** a monorepo with the directory structure, `.gitignore`, environment variable template and README defined,
**so that** every microservice has its place, no secret reaches the repository and anyone can bring the project up by following a single guide.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is finished.

- [x] **AC-1: Monorepo directory tree**
  The structure defined in `CLAUDE.md` is created:
  ```
  autoops/
  ├── apps/
  │   ├── frontend/
  │   └── api_gateway/
  ├── services/
  │   ├── ai-engine/
  │   └── mcp-servers/
  ├── .claude/
  │   ├── CLAUDE.md
  │   └── context/
  │       ├── user_stories/
  │       └── summaries/
  ├── .env.example
  ├── .gitignore
  └── README.md
  ```
  - Empty directories contain a `.gitkeep` so that Git tracks them.
  - No application code is written (no `main.py`, `package.json`, etc.): structure only.
  - `.claude/context/` already exists (with `IMPLEMENTATION_PLAN.md`, `TASK_EXECUTION.md` and the epic folders) and stays there; it is neither moved nor overwritten.

- [x] **AC-2: Strict `.gitignore`**
  A single `.gitignore` at the root covering at least:
  - **Secrets:** `.env`, `.env.*` and `*.pem`, `*.key` (with explicit exception `!.env.example`).
  - **Python:** `venv/`, `.venv/`, `__pycache__/`, `*.py[cod]`, `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`, `.coverage`, `htmlcov/`, `*.egg-info/`.
  - **Node/Frontend:** `node_modules/`, `dist/`, `.vite/`, `*.tsbuildinfo`, `npm-debug.log*`.
  - **Docker/local data:** local data volumes (e.g. `pgdata/`) and `docker-compose.override.yml`.
  - **Log files:** `*.log` (consistent with the stdout/stderr logging rule).
  - **IDE/OS:** `.idea/`, `.vscode/` (except explicit shared configuration), `.DS_Store`, `Thumbs.db`.
  - Verification: manual review of the pattern (`.env` ignored, `.env.example` not); `git check-ignore -v` only if a repo exists.

- [x] **AC-3: Centralized `.env.example`**
  A single template at the root with **all** project variables, grouped into commented sections, using only example values (never real secrets):
  - **Server & Gateway:** `PORT`, `DEBUG`, `ENVIRONMENT`, `SECRET_KEY`
  - **PostgreSQL Database:** `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
  - **AI Models & Telemetry:** `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`, `LANGCHAIN_TRACING_V2`, `LANGCHAIN_API_KEY`
  - **MCP Servers:** `MCP_LOGS_SERVER_URL`, `MCP_DB_SERVER_URL`
  - **Frontend (Vite):** `VITE_API_BASE_URL`, `VITE_WS_BASE_URL`
  - Each section states which service consumes the variables.
  - Example values for keys use obvious placeholders (`tu_clave_openai`, `tu_clave_deepseek`, `cambia_esta_clave`).
  - Rule for future US: every new variable is added here in the same US that introduces it.

- [x] **AC-4: Root `README.md`**
  A document in English that includes:
  1. Brief description of AutoOps and its purpose (autonomous Tier-1 support with Triage/Investigator/Executor agents and HITL).
  2. Summarized tech stack.
  3. Monorepo tree with a one-line purpose per directory.
  4. Prerequisites (Python 3.11+, Node.js, PostgreSQL; Docker in Phase 2).
  5. Getting started: clone, `cp .env.example .env`, and links to the backend/frontend commands (marked as "available after the corresponding US").
  6. Key principles: Twelve-Factor (zero hardcoding), isolation via MCP, logging to stdout/stderr.
  7. SDD workflow: links to `context/IMPLEMENTATION_PLAN.md` and `context/TASK_EXECUTION.md`, and branching strategy (`main`, `develop`, `feature/*`, `fix/*`).

- [x] **AC-5: Final structure validation**
  - `find` / `tree` of the repo shows exactly the tree from AC-1 (no leftover folders).
  - `git status` (only if the repo already exists; it is not initialized in this US) does not list `.env` or ignored artifacts.
  - All variables in `CLAUDE.md` appear in `.env.example` and vice versa (no differences).
  - All relative links in the README resolve to existing files.

---

## Technical Notes

- **Out of scope:** application code, Dockerfiles, `docker-compose.yml` (Phase 2), CI (US-MONO-003), shared configuration/logging (US-MONO-002).
- **Directory name:** `apps/api_gateway/` (underscore) to stay compatible with Python imports and the `uvicorn apps.api_gateway.main:app` command.
- **Location of `context/`:** stays in `.claude/context/` (confirmed decision).
- **Git:** the repository is NOT initialized in this US (confirmed decision); `git check-ignore` and `git status` from AC-2/AC-5 are validated only once the repo exists, or deferred.
