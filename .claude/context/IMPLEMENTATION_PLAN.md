# 🚀 AutoOps - Implementation Plan

<!--
  US states (the title checkbox is the ONLY source of truth):
    [ ]  Pending
    [~]  In progress (only ONE at a time)
    [x]  Completed
  The workflow (TASK_EXECUTION.md) updates this file when closing each US.
-->

**Last updated:** 2026-10-26
**Version:** 2.8

---

## 📊 General Dashboard

```
┌─────────────────────────────────────────────────────────────┐
│  OVERALL PROJECT PROGRESS                                   │
├─────────────────────────────────────────────────────────────┤
│  Total User Stories:             31                         │
│  ✅ Completed:                   24                         │
│  ⏳ In Progress:                 1                          │
│  ⏸️  Pending:                    6                          │
│                                                             │
│  Progress: [████████░░] 77% (24/31)                          │
└─────────────────────────────────────────────────────────────┘
```

<!--
  Reference progress bar (10 characters):
  0%   → [░░░░░░░░░░]    50%  → [█████░░░░░]
  10%  → [█░░░░░░░░░]    60%  → [██████░░░░]
  20%  → [██░░░░░░░░]    70%  → [███████░░░]
  30%  → [███░░░░░░░]    80%  → [████████░░]
  40%  → [████░░░░░░]    90%  → [█████████░]
                          100% → [██████████]
-->

---

## 🎯 Progress by Epic

| Epic | Name | Prefix | Total US | Completed | In Progress | Pending | Progress |
|------|------|--------|----------|-----------|-------------|---------|----------|
| 01 | Monorepo & Base Setup | MONO | 1 | 1 | 0 | 0 | [██████████] 100% |
| 02 | API Gateway & Communications (FastAPI + WebSockets) | GATE | 1 | 1 | 0 | 0 | [██████████] 100% |
| 03 | MCP Servers (Logs and Metrics) | MCP | 1 | 1 | 0 | 0 | [██████████] 100% |
| 04 | AI Engine (LangGraph: Triage and Investigation) | LANG | 1 | 1 | 0 | 0 | [██████████] 100% |
| 05 | Frontend Dashboard (React + Vite + TailwindCSS) | FRONT | 1 | 1 | 0 | 0 | [██████████] 100% |
| 06 | Database & Persistence (PostgreSQL + SQLAlchemy + Alembic) | DB | 2 | 2 | 0 | 0 | [██████████] 100% |
| 07 | AI Integration (Gateway ↔ LangGraph) | INT | 2 | 2 | 0 | 0 | [██████████] 100% |
| 08 | Containerization & Orchestration | DOCK | 4 | 4 | 0 | 0 | [██████████] 100% |
| 09 | Host Access & Identity | HOST | 3 | 3 | 0 | 0 | [██████████] 100% |
| 10 | Network Security | NET | 2 | 2 | 0 | 0 | [██████████] 100% |
| 11 | OS Hardening & Runtime | SYS | 4 | 4 | 0 | 0 | [██████████] 100% |
| 12 | Provisioning | PROV | 1 | 1 | 0 | 0 | [██████████] 100% |
| 13 | Reverse Proxy & TLS (Traefik, self-signed / Let's Encrypt) | PROXY | 3 | 1 | 1 | 1 | [███░░░░░░░] 33% |
| 14 | CI/CD (GitHub Actions, GHCR, self-hosted runner) | CICD | 5 | 0 | 0 | 5 | [░░░░░░░░░░] 0% |

---

## 📅 Implementation Plan by Phase

---

# 🎯 PHASE 1: FOUNDATION AND MULTI-AGENT CORE (Sprint 1-2)

**Goal:** Build the isolated foundations of the microservices (Gateway, AI, MCP, Frontend) and define communication contracts, without deep integration or persistence.
**Epics:** 01 Monorepo & Base Setup, 02 API Gateway & Communications, 03 MCP Servers, 04 AI Engine, 05 Frontend Dashboard
**Total US:** 5
**Progress:** [██████████] 100% (5/5)

> Recommended execution order: 01 → 02 → 03 → 04 → 05 (MCP depends on the Gateway; the AI engine needs MCP and the Gateway; the Frontend consumes the Gateway). The dependencies of each US are the source of truth.

---

## Epic 01: Monorepo & Base Setup - Structure, configuration and base quality

**Priority:** CRITICAL
**Folder:** `context/user_stories/epic_01_monorepo/`

### User Stories

#### [x] US-MONO-001: Monorepo Setup
- **File:** `context/user_stories/epic_01_monorepo/US-MONO-001_monorepo_setup.md`
- **Priority:** CRITICAL
- **Estimate:** 3 pts
- **Dependencies:** None
- **Acceptance Criteria:** 5

---

## Epic 02: API Gateway & Communications - FastAPI, REST and WebSockets

**Priority:** HIGH
**Folder:** `context/user_stories/epic_02_gateway/`

### User Stories

#### [x] US-GATE-002: Base API Gateway Implementation in FastAPI
- **File:** `context/user_stories/epic_02_gateway/US-GATE-002_fastapi_gateway.md`
- **Priority:** CRITICAL
- **Estimate:** 5 pts
- **Dependencies:** US-MONO-001
- **Acceptance Criteria:** 4

---

## Epic 03: MCP Servers - Log and Metrics Inspection

**Priority:** HIGH
**Folder:** `context/user_stories/epic_03_mcp/`

### User Stories

#### [x] US-MCP-003: MCP Server for Simulated Log and Metrics Inspection
- **File:** `context/user_stories/epic_03_mcp/US-MCP-003_logs_mcp_server.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-GATE-002
- **Acceptance Criteria:** 4

---

## Epic 04: AI Engine - LangGraph (Triage and Investigation)

**Priority:** CRITICAL
**Folder:** `context/user_stories/epic_04_ai_engine/`

### User Stories

#### [x] US-LANG-004: Base Agent Graph (Triage and Investigation)
- **File:** `context/user_stories/epic_04_ai_engine/US-LANG-004_langgraph_workflow.md`
- **Priority:** CRITICAL
- **Estimate:** 8 pts
- **Dependencies:** US-MCP-003
- **Acceptance Criteria:** 4

---

## Epic 05: Frontend Dashboard - React + Vite + TailwindCSS

**Priority:** MEDIUM
**Folder:** `context/user_stories/epic_05_frontend/`

### User Stories

#### [x] US-FRONT-005: Admin Dashboard and WebSocket Integration
- **File:** `context/user_stories/epic_05_frontend/US-FRONT-005_react_dashboard.md`
- **Priority:** MEDIUM
- **Estimate:** 5 pts
- **Dependencies:** US-LANG-004
- **Acceptance Criteria:** 4

---

# 🎯 PHASE 2: LOGICAL INTEGRATION AND PERSISTENCE

**Goal:** Integrate the services and persist state: PostgreSQL, ORM, LangGraph-Gateway connection and HITL Executor Agent.
**Epics:** 06 Database & Persistence, 07 AI Integration (rest to be defined)
**Total US:** 4
**Progress:** [██████████] 100% (4/4)

---

## Epic 06: Database & Persistence - PostgreSQL, SQLAlchemy and Alembic

**Priority:** HIGH
**Folder:** `context/user_stories/epic_06_database/`

### User Stories

#### [x] US-DB-001: ORM, Models and Migrations Setup
- **File:** `context/user_stories/epic_06_database/US-DB-001_postgresql_alembic.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** Phase 1 (US-GATE-002)
- **Acceptance Criteria:** 4

#### [x] US-DB-002: Real Persistence and Ticket CRUD
- **File:** `context/user_stories/epic_06_database/US-DB-002_tickets_crud.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-DB-001
- **Acceptance Criteria:** 4

---

## Epic 07: AI Integration - Integrating the API Gateway with LangGraph

**Priority:** HIGH
**Folder:** `context/user_stories/epic_07_integration/`

### User Stories

#### [x] US-INT-001: Background Triage Agent Trigger
- **File:** `context/user_stories/epic_07_integration/US-INT-001_langgraph_trigger.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-DB-002, US-LANG-004
- **Acceptance Criteria:** 3

#### [x] US-INT-002: AI Reasoning Streaming via WebSockets
- **File:** `context/user_stories/epic_07_integration/US-INT-002_websocket_streaming.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-INT-001, US-GATE-002
- **Acceptance Criteria:** 3

---

# 🎯 PHASE 3: ADVANCED CONTAINERIZATION

**Goal:** Dockerfiles, Docker Compose and isolated networks.
**Epics:** 08 Containerization & Orchestration
**Total US:** 4
**Progress:** [██████████] 100% (4/4)

> Recommended order: DOCK-001 → DOCK-002 → DOCK-003 → DOCK-004 (orchestration integrates the three previous images).

---

## Epic 08: Containerization & Orchestration - Dockerfiles, Docker Compose and isolated networks

**Priority:** HIGH
**Folder:** `context/user_stories/epic_08_containerization/`

### User Stories

#### [x] US-DOCK-001: Multi-Stage Builds for API Gateway and AI Engine
- **File:** `context/user_stories/epic_08_containerization/US-DOCK-001_multi_stage_builds.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-INT-002
- **Acceptance Criteria:** 3

#### [x] US-DOCK-002: Multi-Stage Dockerfile for the Frontend (Vite + Nginx)
- **File:** `context/user_stories/epic_08_containerization/US-DOCK-002_frontend_dockerfile.md`
- **Priority:** HIGH
- **Estimate:** 3 pts
- **Dependencies:** US-DOCK-001
- **Acceptance Criteria:** 3

#### [x] US-DOCK-003: Dockerfiles for the MCP Servers
- **File:** `context/user_stories/epic_08_containerization/US-DOCK-003_mcp_servers_dockerfiles.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-DOCK-001, US-MCP-003
- **Acceptance Criteria:** 3

#### [x] US-DOCK-004: Global Orchestration with Docker Compose
- **File:** `context/user_stories/epic_08_containerization/US-DOCK-004_docker_compose_orchestration.md`
- **Priority:** HIGH
- **Estimate:** 8 pts
- **Dependencies:** US-DOCK-001, US-DOCK-002, US-DOCK-003
- **Acceptance Criteria:** 4

---

# 🎯 PHASE 4: LINUX INFRASTRUCTURE AND SECURITY

**Goal:** Deliver a dedicated, hardened and reproducible Ubuntu Server 26.04 (validated on a clean VirtualBox VM; EC2 as the final target) that runs the Compose stack as a systemd service, ready for Phase 5.
**Epics:** 09 Host Access & Identity, 10 Network Security, 11 OS Hardening & Runtime, 12 Provisioning
**Total US:** 10 (54 pts)
**Progress:** [██████████] 100% (10/10)

> Decisions: provisioning with **idempotent Bash scripts + `verify.sh`** (no Ansible); **standard Docker** with a hardened `daemon.json` (no rootless); `auditd`/Lynis **excluded**.
> Recommended order: HOST-001 → HOST-002 → HOST-003 → NET-001 → SYS-001 → SYS-002 → NET-002 → SYS-003 → SYS-004 → PROV-001. NET-002 comes after SYS-002 because it needs Docker installed; PROV-001 integrates everything.
> Convention: each US contributes its script in `scripts/provision/NN_name.sh` and its check in `scripts/provision/checks/`; configuration templates live in `infra/`.

---

## Epic 09: Host Access & Identity - Users, SSH and access protection

**Priority:** CRITICAL
**Folder:** `context/user_stories/epic_09_host_access/`

### User Stories

#### [x] US-HOST-001: Native Users and Privilege Model
- **File:** `context/user_stories/epic_09_host_access/US-HOST-001_native_users_privileges.md`
- **Priority:** CRITICAL
- **Estimate:** 5 pts
- **Dependencies:** US-DOCK-004
- **Acceptance Criteria:** 4

#### [x] US-HOST-002: SSH Hardening and Key Management
- **File:** `context/user_stories/epic_09_host_access/US-HOST-002_ssh_hardening_keys.md`
- **Priority:** CRITICAL
- **Estimate:** 5 pts
- **Dependencies:** US-HOST-001
- **Acceptance Criteria:** 4

#### [x] US-HOST-003: Brute-Force Protection (fail2ban)
- **File:** `context/user_stories/epic_09_host_access/US-HOST-003_fail2ban.md`
- **Priority:** HIGH
- **Estimate:** 3 pts
- **Dependencies:** US-HOST-002
- **Acceptance Criteria:** 3

---

## Epic 10: Network Security - Firewall and Docker ↔ UFW coherence

**Priority:** CRITICAL
**Folder:** `context/user_stories/epic_10_network_security/`

### User Stories

#### [x] US-NET-001: UFW Firewall with Deny-by-Default Policy
- **File:** `context/user_stories/epic_10_network_security/US-NET-001_ufw_firewall.md`
- **Priority:** CRITICAL
- **Estimate:** 5 pts
- **Dependencies:** US-HOST-002
- **Acceptance Criteria:** 3
- **Note:** opening 80/443 (AC-2) is deferred to Phase 5; for now it is opt-in via `UFW_WEB_PORTS` (by default, no web port).

#### [x] US-NET-002: Docker ↔ UFW Coherence
- **File:** `context/user_stories/epic_10_network_security/US-NET-002_docker_ufw_coherence.md`
- **Priority:** CRITICAL
- **Estimate:** 5 pts
- **Dependencies:** US-NET-001, US-SYS-002
- **Acceptance Criteria:** 4
- **Decision (AC-3):** Gateway (`PORT`) and frontend (`FRONTEND_PORT`) remain provisionally public via the `DOCKER-USER` allowed-ports list; the Gateway is closed in Phase 5 with the reverse proxy. Docker-managed `iptables` is kept (no `"iptables": false`).
- **Order:** runs after US-SYS-002 (needs Docker installed).

---

## Epic 11: OS Hardening & Runtime - OS baseline, Docker Engine and systemd

**Priority:** HIGH
**Folder:** `context/user_stories/epic_11_os_runtime/`

### User Stories

#### [x] US-SYS-001: OS Baseline and Automatic Patching
- **File:** `context/user_stories/epic_11_os_runtime/US-SYS-001_os_baseline.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-HOST-001
- **Acceptance Criteria:** 4

#### [x] US-SYS-002: Docker Engine on the Host and Hardened `daemon.json`
- **File:** `context/user_stories/epic_11_os_runtime/US-SYS-002_docker_engine_daemon.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-SYS-001
- **Acceptance Criteria:** 4

#### [x] US-SYS-003: systemd Service for the AutoOps Stack
- **File:** `context/user_stories/epic_11_os_runtime/US-SYS-003_systemd_service.md`
- **Priority:** HIGH
- **Estimate:** 8 pts
- **Dependencies:** US-HOST-001, US-SYS-002, US-NET-002
- **Acceptance Criteria:** 4

#### [x] US-SYS-004: PostgreSQL Backups with systemd Timer
- **File:** `context/user_stories/epic_11_os_runtime/US-SYS-004_postgres_backups_timer.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-SYS-003
- **Acceptance Criteria:** 4

---

## Epic 12: Provisioning - Idempotent bootstrap and verification

**Priority:** HIGH
**Folder:** `context/user_stories/epic_12_provisioning/`

### User Stories

#### [x] US-PROV-001: Idempotent Bootstrap and Host Verification
- **File:** `context/user_stories/epic_12_provisioning/US-PROV-001_bootstrap_verify.md`
- **Priority:** HIGH
- **Estimate:** 8 pts
- **Dependencies:** All US of epics 09, 10 and 11
- **Acceptance Criteria:** 4

---

# 🎯 PHASE 5: SECURE EXPOSURE AND CI/CD

**Goal:** Expose the stack only through a Traefik reverse proxy with TLS, and deploy it continuously: images built in the cloud (GitHub Actions → GHCR) and pulled by a self-hosted runner on the host.
**Epics:** 13 Reverse Proxy & TLS, 14 CI/CD
**Total US:** 8 (47 pts)
**Progress:** [█░░░░░░░░░] 13% (1/8)

> Decisions:
> - **Proxy:** Traefik with the **file provider**; `docker.sock` is never mounted. Single domain, path routing (`/` frontend, `/api` and `/ws` gateway), new `edge_net`.
> - **TLS:** the host has no public IP or domain (VirtualBox behind residential NAT). Locally, **self-signed certificates are generated during provisioning**; **Let's Encrypt (HTTP-01)** is prepared and switchable through environment variables for production.
> - **Registry:** images are built in GitHub Actions and published to **GHCR**; the host never builds, it only pulls.
> - **Deployment is pull-based:** GitHub cannot reach the host through NAT, so a **containerized self-hosted runner** on the host executes the deploy job. The SSH deploy key from US-HOST-002 is not used by this flow.
> - Recommended order: PROXY-001 → 002 → 003 → CICD-001 → 002 → 003 → 004 → 005.
> - The runner must not get `docker.sock` (root-equivalent). The mechanism for it to hand a validated image tag to the host is designed in US-CICD-004.

---

## Epic 13: Reverse Proxy & TLS - Traefik, self-signed certificates and Let's Encrypt

**Priority:** HIGH
**Folder:** `context/user_stories/epic_13_reverse_proxy/`

### User Stories

#### [x] US-PROXY-001: Traefik as the Single Entry Point (HTTP) and Compose Integration
- **File:** `context/user_stories/epic_13_reverse_proxy/US-PROXY-001_traefik_entrypoint.md`
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-DOCK-004, US-NET-002
- **Acceptance Criteria:** 4

#### [~] US-PROXY-002: TLS: Local CA with Self-Signed Certificates and Let's Encrypt HTTP-01
- **File:** `context/user_stories/epic_13_reverse_proxy/US-PROXY-002_tls.md`
- **Priority:** HIGH
- **Estimate:** 8 pts
- **Dependencies:** US-PROXY-001, US-SYS-003
- **Acceptance Criteria:** 5
- **Decisions:** local root CA (importable once on the host machine) signs the leaf; HTTP→HTTPS redirect is mandatory in every mode; `TLS_MODE` (`selfsigned`|`acme`) has no default; the CA key never reaches the proxy.

#### [ ] US-PROXY-003: Close the Perimeter *(to be written)*
- **Priority:** HIGH
- **Estimate:** 3 pts
- **Dependencies:** US-PROXY-002
- **Scope:** `UFW_WEB_PORTS=80,443`, `DOCKER_PUBLIC_PORTS=80,443` (retire `PORT`/`FRONTEND_PORT`), new `verify.sh` checks, `infra/` docs.

---

## Epic 14: CI/CD - GitHub Actions, GHCR and self-hosted runner

**Priority:** HIGH
**Folder:** `context/user_stories/epic_14_cicd/`

### User Stories

#### [ ] US-CICD-001: CI Pipeline *(to be written)*
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** Phase 4 (independent of Epic 13)
- **Scope:** GitHub-hosted runners: pytest, frontend lint/typecheck/build, `docker compose config`, shellcheck.

#### [ ] US-CICD-002: Build and Publish Images to GHCR *(to be written)*
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-CICD-001, US-PROXY-002
- **Scope:** images tagged by commit SHA; `docker-compose.yml` consumes `image: ghcr.io/...:${IMAGE_TAG}` and keeps `build:` for development; `VITE_*` passed as build-args.

#### [ ] US-CICD-003: Containerized Self-Hosted Runner on the Host *(to be written)*
- **Priority:** HIGH
- **Estimate:** 8 pts
- **Dependencies:** US-CICD-002, US-SYS-003
- **Scope:** runner container provisioned by a numbered script (registration token from the environment, never committed), isolated network, no `docker.sock`, restricted labels and repository, outbound-only connection to GitHub; check in `verify.sh`.

#### [ ] US-CICD-004: Pull-Based Deployment on the Host *(to be written)*
- **Priority:** CRITICAL
- **Estimate:** 8 pts
- **Dependencies:** US-CICD-003, US-SYS-004
- **Scope:** host-side deploy action with strict tag validation, image pull, migrations, `systemctl reload autoops`, health-gate and automatic rollback to the previous tag; handoff mechanism from the runner to the host.

#### [ ] US-CICD-005: CD Workflow, Smoke Test and Phase Closing *(to be written)*
- **Priority:** HIGH
- **Estimate:** 5 pts
- **Dependencies:** US-CICD-004
- **Scope:** workflow chaining CI → build → deploy job on the self-hosted runner, post-deploy smoke test over HTTPS, rollback evidence, documentation, phase 5 summary.

---

## 📝 Implementation Notes

### How to use this plan

1. **Follow the phase order** — always start with Phase 1
2. **Incremental work** — complete one US before moving on
3. **Mark progress** with the title checkbox: `[ ]` pending, `[~]` in progress (only ONE), `[x]` completed
4. **Update metrics** — when closing each US: dashboard, epic row in the table, phase bar and "Last updated"
5. **Read each US file** — it contains the detailed acceptance criteria
6. **Write the US before implementing it** — those marked *(to be written)* do not have a file yet; they are written (and validated with the user) right before starting

### Project references

- **Path note:** `context/...` is relative to `.claude/` (final location: `.claude/context/`)
- **User stories:** `context/user_stories/`
- **Execution workflow:** `@context/TASK_EXECUTION.md`
- **Phase summaries:** `context/summaries/`
- **Technical details:** `@CLAUDE.md`
