# US-LANG-004: Base Agent Graph (Triage and Investigation)

**Epic:** 04 — AI Engine (LangGraph)
**Priority:** CRITICAL
**Estimate:** 8 pts
**Dependencies:** US-MCP-003
**Status:** Completed

---

## User Story

**As** an autonomous system,
**I need** a multi-agent engine based on LangGraph that processes an incoming ticket, classifies its severity through a Triage Agent and then invokes an Investigator Agent prepared to use MCP tools,
**so that** we have the base analysis flow on which the real investigation and the Executor Agent will be built.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is finished and pause at the final checkpoint before closing the US.

- [x] **AC-1: Base structure and instantiation**
  - The folder `services/ai-engine/` is created.
  - `requirements.txt` is created with `langgraph`, `langchain-openai` (DeepSeek through its OpenAI-compatible API), `langchain-core`, `pydantic` and `mcp<2` (MCP client).
  - The model and its key are configured via environment variables (`DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL` and `AI_MODEL_NAME`, all in `.env.example`); no hardcoded values.
  - **Verification:** dependencies install and the package modules import without errors.

- [x] **AC-2: Graph State definition (`state.py`)**
  - `AgentState` (`TypedDict`) is created with the fields: `ticket_id`, `description`, `severity`, `agent_notes`, `status` and `messages` (LangChain message history, with the `add_messages` reducer).
  - `severity` is restricted to `low | medium | high | critical` (same values as the Gateway's `TicketSeverity`).
  - **Verification:** the state imports and a sample dictionary satisfies the typing.

- [x] **AC-3: Initial Nodes (`nodes.py`)**
  - `triage_node`: uses a base prompt to analyze `description` and assigns a valid severity; if the model returns a value outside the set, it applies a safe default and logs it.
  - `investigator_node`: reacts to the severity and records the gathered technical context in `agent_notes`; leaves an explicit injection point for the MCP client (not connected yet).
  - Each node receives the model/client as an injected dependency, so they can be tested with a fake model without calling the API.
  - **Verification:** tests with a fake model: triage returns a valid severity and the investigator adds notes without breaking the state.

- [x] **AC-4: Routing and Compilation (`graph.py`)**
  - The flow `START -> triage_node -> investigator_node -> END` is configured.
  - The compiled graph is exposed as `compiled_graph`, invocable externally.
  - **Verification:** `compiled_graph.invoke(...)` with a fake model traverses both nodes and returns the final state with `severity` and `agent_notes` populated.

---

## Technical Notes

- **Isolation (MCP):** the AI engine NEVER connects to PostgreSQL or runs OS commands; infrastructure is only queried through MCP servers. In this US the MCP client remains an injection point, with no real connection.
- **Twelve-Factor:** model, keys and MCP server paths come from environment variables, documented in `.env.example`.
- **Logging:** stdout/stderr only.
- **Out of scope:** effective connection to the logs MCP server, Executor Agent, HITL approval, integration with the Gateway and state persistence.
- **Conventions:** files and functions in `snake_case`; classes and types in `PascalCase`.
