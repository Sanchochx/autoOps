"""Tests of the background triage service (mocked graph and session)."""

import asyncio
import json
from collections.abc import AsyncIterator
from typing import Any
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from apps.api_gateway.models import Ticket
from apps.api_gateway.schemas import TicketSeverity, TicketStatus
from apps.api_gateway.services.ai_service import process_ticket_with_ai

pytestmark = pytest.mark.anyio


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


class FakeSessionFactory:
    """Mimic ``async_sessionmaker``: ``factory()`` is an async context manager."""

    def __init__(self, session: AsyncMock) -> None:
        self.session = session

    def __call__(self) -> "FakeSessionFactory":
        return self

    async def __aenter__(self) -> AsyncMock:
        return self.session

    async def __aexit__(self, *exc: object) -> None:
        return None


@pytest.fixture
def session() -> AsyncMock:
    return AsyncMock()


@pytest.fixture
def ticket() -> Ticket:
    return Ticket(
        id=uuid4(),
        title="BD lenta",
        description="La BD responde lento",
        severity=TicketSeverity.MEDIUM,
        status=TicketStatus.OPEN,
    )


class FakeGraph:
    """Mock graph: ``astream`` emits the given per-node updates."""

    def __init__(self, updates: list[dict[str, Any]] | None = None, error: Exception | None = None):
        self.updates = updates or []
        self.error = error
        self.inputs: list[Any] = []
        self.stream_modes: list[str] = []

    async def astream(self, graph_input: Any, stream_mode: str) -> AsyncIterator[dict[str, Any]]:
        self.inputs.append(graph_input)
        self.stream_modes.append(stream_mode)
        for update in self.updates:
            yield update
        if self.error:
            raise self.error


TRIAGE_UPDATES: list[dict[str, Any]] = [
    {"triage_node": {"severity": "critical", "agent_notes": ["triage: severidad = critical"]}},
    {
        "investigator_node": {
            "status": "investigated",
            "analysis": "Pool de conexiones saturado",
            "agent_notes": ["investigator: Pool de conexiones saturado"],
        }
    },
]


@pytest.fixture
def ws_manager() -> MagicMock:
    manager = MagicMock()
    manager.broadcast = AsyncMock()
    return manager


def _sent(ws_manager: MagicMock) -> list[dict[str, Any]]:
    return [json.loads(call.args[0]) for call in ws_manager.broadcast.await_args_list]


async def test_updates_severity_and_status_from_graph(
    session: AsyncMock, ticket: Ticket, ws_manager: MagicMock
) -> None:
    session.get.return_value = ticket
    graph = FakeGraph(TRIAGE_UPDATES)

    await process_ticket_with_ai(ticket.id, graph, FakeSessionFactory(session), ws_manager)

    assert graph.inputs == [{"ticket_id": str(ticket.id), "description": "La BD responde lento"}]
    assert graph.stream_modes == ["updates"]
    assert ticket.severity is TicketSeverity.CRITICAL
    assert ticket.analysis == "Pool de conexiones saturado"
    assert ticket.status is TicketStatus.ESCALATED
    # One commit when the graph starts (investigating), one with the result (escalated).
    assert session.commit.await_count == 2


async def test_emits_one_event_per_step_with_contract(
    session: AsyncMock, ticket: Ticket, ws_manager: MagicMock
) -> None:
    session.get.return_value = ticket

    await process_ticket_with_ai(
        ticket.id, FakeGraph(TRIAGE_UPDATES), FakeSessionFactory(session), ws_manager
    )

    events = _sent(ws_manager)
    assert [e["node"] for e in events] == [
        "gateway", "triage_node", "investigator_node", "database"
    ]
    assert all(e["type"] == "ai_event" and e["ticket_id"] == str(ticket.id) for e in events)
    assert events[1]["message"] == "triage: severidad = critical"


async def test_missing_ticket_skips_graph(session: AsyncMock, ws_manager: MagicMock) -> None:
    session.get.return_value = None
    graph = FakeGraph(TRIAGE_UPDATES)

    await process_ticket_with_ai(uuid4(), graph, FakeSessionFactory(session), ws_manager)

    assert graph.inputs == []
    session.commit.assert_not_awaited()
    ws_manager.broadcast.assert_not_awaited()


async def test_graph_failure_keeps_ticket_and_does_not_raise(
    session: AsyncMock, ticket: Ticket, ws_manager: MagicMock
) -> None:
    session.get.return_value = ticket
    graph = FakeGraph(error=RuntimeError("LLM caído"))

    await process_ticket_with_ai(ticket.id, graph, FakeSessionFactory(session), ws_manager)

    assert ticket.severity is TicketSeverity.MEDIUM
    assert ticket.status is TicketStatus.OPEN
    assert ticket.analysis is None
    assert _sent(ws_manager)[-1]["node"] == "error"


async def test_graph_failure_after_start_returns_ticket_to_open(
    session: AsyncMock, ticket: Ticket, ws_manager: MagicMock
) -> None:
    session.get.return_value = ticket
    graph = FakeGraph(TRIAGE_UPDATES[:1], error=RuntimeError("LLM caído"))

    await process_ticket_with_ai(ticket.id, graph, FakeSessionFactory(session), ws_manager)

    assert ticket.status is TicketStatus.OPEN
    assert ticket.analysis is None
    # investigating on start, open again after the failure.
    assert session.commit.await_count == 2


async def test_ticket_deleted_during_run_is_discarded(
    session: AsyncMock, ticket: Ticket, ws_manager: MagicMock
) -> None:
    session.get.side_effect = [ticket, None]

    await process_ticket_with_ai(
        ticket.id, FakeGraph(TRIAGE_UPDATES), FakeSessionFactory(session), ws_manager
    )

    assert session.commit.await_count == 1
    assert "error" not in [e["node"] for e in _sent(ws_manager)]


async def test_broadcast_failure_does_not_stop_triage(
    session: AsyncMock, ticket: Ticket, ws_manager: MagicMock
) -> None:
    session.get.return_value = ticket
    ws_manager.broadcast.side_effect = RuntimeError("socket roto")

    await process_ticket_with_ai(
        ticket.id, FakeGraph(TRIAGE_UPDATES), FakeSessionFactory(session), ws_manager
    )

    assert ticket.status is TicketStatus.ESCALATED


async def test_slow_client_does_not_block_triage(
    session: AsyncMock, ticket: Ticket, ws_manager: MagicMock, monkeypatch: pytest.MonkeyPatch
) -> None:
    session.get.return_value = ticket
    monkeypatch.setenv("WS_BROADCAST_TIMEOUT_SECONDS", "0.05")

    async def never_returns(_: str) -> None:
        await asyncio.sleep(10)

    ws_manager.broadcast.side_effect = never_returns

    await asyncio.wait_for(
        process_ticket_with_ai(
            ticket.id, FakeGraph(TRIAGE_UPDATES), FakeSessionFactory(session), ws_manager
        ),
        timeout=3,
    )

    assert ticket.status is TicketStatus.ESCALATED
