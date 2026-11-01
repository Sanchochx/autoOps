# US-FE-001: Ticket Management from the Dashboard

**Epic:** 15 — Frontend Ticket Management
**Priority:** HIGH
**Estimate:** 5 pts
**Dependencies:** US-FRONT-005, US-PROXY-001
**Status:** Done

---

## User Story

**As** an AutoOps operator (or someone evaluating the project),
**I need** to create tickets and see the list of tickets from the React dashboard, next to the live agent console,
**so that** the whole flow (ticket → triage → investigation) can be demonstrated from the browser without `curl`.

---

## Decisions

- **Same-origin, relative paths.** The client calls `/api/v1/tickets` (never a hardcoded host). Behind Traefik the build uses `VITE_API_BASE_URL=/`, so the path is joined to the base without producing `//api/...`; in development an absolute base (`http://localhost:8000`) is also accepted (CORS already allows it). Zero hardcoding: the base comes from `VITE_API_BASE_URL`.
- **Only `title` and `description` are typed by the user.** The payload always carries `severity: "medium"`, because `TicketCreate` requires it. The gateway ignores the submitted value and the Triage Agent assigns the real severity in the background, so the table is the place where the agent's result shows up.
- **No new backend work.** `POST /api/v1/tickets` and `GET /api/v1/tickets` exist; this story is frontend-only. No authentication exists on these endpoints yet, so none is added.
- **Layout:** CSS Grid on the dashboard. On `lg:` the ticket form + list sit in the left column and the live console in the right one; below `lg:` everything stacks (mobile-first), console last. Tabs were rejected: the point of the demo is to see the ticket and the agent stream at once.
- **Keeping the list fresh:** refetch after a successful creation and poll `GET` at an interval read from `VITE_TICKETS_POLL_INTERVAL_MS` (default 5000, `0` disables) so the severity/status changes made by the agent appear without a manual reload. Polling pauses while the tab is hidden. (No new WebSocket event type is invented.)
- **Follows the existing frontend standards** (CLAUDE.md): feature folder `features/tickets/{components,hooks,services,models}` with a barrel `index.ts`, strict TypeScript without `any`, components ≤ ~150 lines and free of API calls, Zustand/hooks for state, Tailwind consistent with the current slate/sky palette, UI copy in Spanish like the existing console.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: Ticket Model and API Client**
  - `features/tickets/models`: `Ticket`, `TicketSeverity`, `TicketStatus` and `NewTicketInput` types matching `TicketRead`/`TicketCreate`. `features/tickets/services`: `createTicket(input)` (POST, injects `severity: 'medium'`) and `listTickets()` (GET), both through a shared URL builder that joins `VITE_API_BASE_URL` and `/api/v1/tickets` safely.
  - Responses are validated with a type guard (`unknown` → `Ticket`), not cast; non-2xx responses raise a typed error carrying the status and the gateway `detail` when present.
  - **Verification:** unit tests (Vitest if absent from the project, added as dev dependency) for the URL builder (`/`, empty, `http://host:8000`, trailing slashes), the injected payload and the error path; `npm run lint`, `typecheck` and `build` stay green.

- [x] **AC-2: Create-Ticket Form**
  - `TicketForm` with a labelled `title` input and `description` textarea (explicit `<label>`), submit button, client-side required validation, disabled/“Creando…” state while pending, inline error (`role="alert"`) on failure and a polite success message; fields clear on success. Logic lives in a `useCreateTicket` hook.
  - **Verification:** with the stack up, creating a ticket from the UI returns 201 and the request in the browser Network tab goes to the relative `/api/v1/tickets` with `severity: "medium"`; an empty field is blocked; stopping the gateway shows the error message, not a crash.

- [x] **AC-3: Ticket List**
  - `TicketList` (table on `md:`+, stacked cards or horizontally scrollable table on mobile) showing ID (short form, full value in `title`/accessible text), title, status badge, severity badge (colors meet WCAG AA 4.5:1, never color alone) and creation time; most recent first as returned by the API. Loading, empty and error states, each with a retry where applicable. Logic in a `useTickets` hook with the refetch-after-create and polling behavior from Decisions.
  - **Verification:** a ticket created in AC-2 appears without reloading; after the Triage Agent finishes, its severity/status updates on the next poll; polling stops when the tab is hidden and when the component unmounts (no request leaks).

- [x] **AC-4: Dashboard Layout with the Live Console**
  - `App`/`DashboardLayout` compose `TicketForm`, `TicketList` and the existing `AgentConsole` in a responsive CSS Grid as described in Decisions; `lazy`/`Suspense` for the ticket feature; the Sidebar keeps working. Existing console and WebSocket behavior are untouched.
  - **Verification:** at ≥ `lg` the three components are visible together; at mobile width they stack without horizontal page overflow; creating a ticket shows the agent messages in the console while the row appears in the list; keyboard-only navigation reaches every control with a visible `:focus-visible`.

- [x] **AC-5: Proxy Integration, Documentation and Evidence**
  - Verified end to end through Traefik over HTTPS (`docker compose up -d --build`): the UI is served at `/`, the calls go to `/api/v1/tickets` on the same origin with no CORS or mixed-content errors. `VITE_TICKETS_POLL_INTERVAL_MS` documented in `.env.example` and `apps/frontend/README.md` (and passed as a build-arg in Compose only if it must be build-time). `IMPLEMENTATION_PLAN.md` updated (Epic 15 row, metrics).
  - **Verification:** screenshot or notes of the full flow (create → console stream → severity assigned) recorded in the PR; CI (`ci`) green including frontend lint/typecheck/build.

---

## Technical Notes

- **Agent column (post-AC addition):** the list shows the agents' progress per ticket (triage → investigating → saving → done/failed) plus the investigator's analysis in an expandable "View analysis". It is derived from the existing `ai_event` WebSocket frames (`ticket_id`, `node`, `message`) in a store of the agent-console feature; nothing is persisted, so tickets processed before the page was opened show "—". Persisting the analysis would need a backend change (new column) and is out of scope here.

- **Closing note (AC-5):** marked complete at the product owner's request; the browser walkthrough through Traefik was run by the product owner, not by Claude (Docker was not accessible to the Claude Code user). That walkthrough surfaced tickets stuck in "investigating" (LLM configuration, not the UI); the AI engine config now requires `OPENAI_API_KEY` explicitly (optional `OPENAI_BASE_URL`), with `.env.example`/Compose/CLAUDE.md updated. `VITE_TICKETS_POLL_INTERVAL_MS` is also a Compose/Dockerfile build-arg.

- **Why `severity: "medium"` is sent at all:** the schema requires it and the router overrides it with `medium`; the agent's classification arrives later via the background task, which is what the list will display.
- **Out of scope:** ticket detail view, editing/closing tickets, HITL approval UI, authentication, pagination/filtering (the list endpoint returns all tickets), new backend endpoints or WebSocket event types.
