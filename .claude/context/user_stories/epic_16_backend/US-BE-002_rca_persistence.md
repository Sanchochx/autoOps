# US-BE-002: Persist the AI Root-Cause Analysis and Close the Ticket Lifecycle

**Epic:** 16 — Backend Ticket Lifecycle
**Priority:** HIGH
**Estimate:** 5 pts
**Dependencies:** US-INT-001, US-INT-002, US-DB-001, US-FE-001
**Status:** Done

---

## User Story

**As** an SRE operator,
**I need** the Investigator's root-cause analysis (RCA) to be stored on the ticket and the ticket to end in a meaningful final state,
**so that** the analysis survives a page reload (F5) and any API client, and a ticket no longer stays at "investigating" after the agents are done.

---

## Decisions

- **New column `tickets.analysis` (`TEXT`, nullable).** Nullable because tickets exist before (and without) any analysis.
- **New status value `escalated`.** The agents can diagnose but cannot remediate (there is no Executor yet), so a successfully investigated ticket is *escalated to a human* with the RCA attached. `resolved` is **not** used by this story: it is reserved for the Executor / HITL flow, which would otherwise have nothing to set. `escalated` is added to the PostgreSQL enum `ticket_status` and to `TicketStatus`.
- **Lifecycle:** `open` → (graph starts) `investigating` → (graph succeeds) `escalated` with `analysis` + final `severity`. **On failure the ticket returns to `open`, `analysis` stays null** and the error is logged to stderr and emitted as the existing `error` WebSocket event. This extends US-INT-001, where `investigating` was set only at the end and was the terminal state.
- **Enum migration is non-transactional.** `ALTER TYPE ... ADD VALUE` cannot run inside a transaction block on the PostgreSQL versions in use, so the migration uses `op.get_context().autocommit_block()`. The downgrade drops the column and **does not remove the enum value** (PostgreSQL cannot drop a value); this is documented in the migration.
- **Where the logic lives.** The AI engine still never touches PostgreSQL (CLAUDE.md rule 2 is about the engine reaching infrastructure directly). The graph returns the analysis in its state; the Gateway's `process_ticket_with_ai` persists it, exactly where severity is persisted today. The Investigator's text is taken from the final graph state, not parsed from the WebSocket message.
- **API:** `analysis` is added to `TicketRead` (so it reaches `GET /api/v1/tickets` and the single-ticket endpoint) and is optional in `TicketUpdate`. It is **not** accepted by `TicketCreate`: only the agent writes it.
- **Frontend: the API is the source of truth.** The table shows `analysis` and `status` from `TicketRead`. The live WebSocket activity (US-FE-001 "Agent" column) remains only for in-flight progress and is overridden by persisted data once present. Nothing is lost on F5.
- **No new endpoints, no auth changes, grid layout untouched.**

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: Alembic Migration, Model and Schemas**
  - Migration `0002`: adds `tickets.analysis TEXT NULL` and the `escalated` value to the `ticket_status` enum (autocommit block). Downgrade drops the column and documents that the enum value stays.
  - `Ticket.analysis: Mapped[str | None]`, `TicketStatus.ESCALATED = "escalated"`, `TicketRead.analysis: str | None`, `TicketUpdate.analysis: str | None`.
  - **Verification:** on a scratch PostgreSQL, `alembic upgrade head` from `0001` with existing rows succeeds and keeps them (analysis null); `downgrade -1` works; `alembic upgrade head` is idempotent when re-run; REST tests show `analysis` in the responses and a `PATCH` can set it.

- [x] **AC-2: Investigation Result Carries the RCA**
  - The graph state exposes the Investigator's final text as a dedicated field (`analysis`), set by `investigator_node`; the existing `agent_notes` and `messages` behavior is unchanged.
  - **Verification:** with the fake model, the graph result contains `analysis` equal to the investigator response; existing graph tests still pass.

- [x] **AC-3: Gateway Persists the RCA and Drives the Lifecycle**
  - `process_ticket_with_ai`: commits `status=investigating` when the graph starts; on success commits `severity`, `analysis` and `status=escalated`; on any failure rolls back to `status=open` (analysis null), logs the exception and emits the `error` event. A ticket deleted meanwhile is skipped without an error.
  - **Verification:** tests with a fake graph/session cover success (severity, analysis and `escalated` persisted), failure (back to `open`, no analysis, `error` event emitted) and a missing ticket; the full pytest suite is green.

- [x] **AC-4: Frontend Shows the Persisted Analysis and Final State**
  - `Ticket` model and the API guard include `analysis` (string or null) and the `escalated` status; a status badge ("Escalated") with AA contrast. The "Agent" column renders the persisted `analysis` (expandable "View analysis") when present, falling back to the live WebSocket activity only while the ticket is in flight.
  - **Verification:** Vitest covers the guard with and without `analysis` and the new status; after the agent finishes and the page is reloaded (F5) the same analysis and `Escalated` badge appear; the grid layout and the console are visually unchanged.

- [x] **AC-5: Rollout, Documentation and Evidence**
  - `0002` is applied explicitly with `docker compose --profile tools run --rm migrate` (the `migrate` service is deliberately **not** run by `up`; the CD deploy runs it as a step) on an existing database without data loss; README/US notes updated (`analysis`, `escalated`, the failure rule); `IMPLEMENTATION_PLAN.md` gets the Epic 16 row; the `ci` check is green.
  - **Verification:** on the running stack (after the explicit migrate step), create a ticket, wait until it shows `Escalated`, reload the page and confirm the analysis is still there; stop the LLM (invalid key) and confirm a new ticket returns to `Open` with the error visible in the console.

---

## Technical Notes

- **Incident during AC-5:** a manual `docker compose up -d --build` returned HTTP 500 on `/api/v1/tickets` (`column tickets.analysis does not exist`) because the migration had not been applied: `migrate` lives in the `tools` profile and `up` never runs it. The code was correct; the earlier claim that `up` applied the migration was wrong. Fix: run the migrate step (below) after pulling a release that adds a migration.
  `sudo docker compose --profile tools run --rm migrate`

- **AC-5 evidence:** confirmed by the product owner on the running stack after `docker compose --profile tools run --rm migrate` (`Running upgrade 0001 -> 0002`): ticket reaches `Escalated` with its analysis, which survives F5. Claude did not observe the run (no Docker access).
- **AC-1 verification gap:** no PostgreSQL server was available where this was implemented (client tools only), so the migration was checked as generated SQL (`alembic upgrade 0001:0002 --sql` / `downgrade 0002:0001 --sql`: `ALTER TYPE ... ADD VALUE IF NOT EXISTS` outside the transaction, then `ADD COLUMN analysis TEXT`), not executed. Running it on a real database is part of AC-5.

- **Existing data:** tickets already stuck at `investigating` from the previous behavior keep that value (they have no analysis). Cleaning them up is out of scope; the "Clear Tickets" action can remove them.
- **Related uncommitted work:** the "Clear Tickets" button and `DELETE /api/v1/tickets` are separate from this story and should be committed on their own.
- **Out of scope:** the Executor Agent and HITL approval (`pending_approval`, `resolved`), connecting the Investigator to the MCP servers, retries or queues, pagination, and authentication.
