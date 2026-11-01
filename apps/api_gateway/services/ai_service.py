"""Service that invokes the LangGraph graph for a newly created ticket."""

import asyncio
import json
import logging
import os
from typing import Any
from uuid import UUID

from apps.api_gateway.connection_manager import ConnectionManager
from apps.api_gateway.connection_manager import manager as default_manager
from apps.api_gateway.database import get_session_factory
from apps.api_gateway.models import Ticket
from apps.api_gateway.schemas import TicketSeverity, TicketStatus

logger = logging.getLogger(__name__)


def _load_compiled_graph() -> Any:
    """Lazily import the compiled graph built with the environment model."""
    from ai_engine.graph import compiled_graph

    return compiled_graph


def _build_event(ticket_id: UUID, node: str, message: str) -> str:
    """Serialize an agent event according to the WebSocket contract."""
    return json.dumps(
        {"type": "ai_event", "ticket_id": str(ticket_id), "node": node, "message": message}
    )


async def _emit(manager: ConnectionManager, ticket_id: UUID, node: str, message: str) -> None:
    """Broadcast an event to clients without a failure affecting triage.

    The send has a maximum time (``WS_BROADCAST_TIMEOUT_SECONDS``) so a slow
    client does not hold up the background task.
    """
    timeout = float(os.environ.get("WS_BROADCAST_TIMEOUT_SECONDS", "2"))
    try:
        await asyncio.wait_for(
            manager.broadcast(_build_event(ticket_id, node, message)), timeout=timeout
        )
    except Exception:
        logger.warning("No se pudo emitir el evento '%s' del ticket %s", node, ticket_id)


def _describe_update(node: str, update: dict[str, Any]) -> str:
    """Summarize a node update (the agent's last note, if any)."""
    notes = update.get("agent_notes") or []
    if notes:
        return str(notes[-1])
    return f"Nodo {node} finalizado"


async def _revert_to_open(factory: Any, ticket_id: UUID) -> None:
    """Return a ticket left in ``investigating`` to ``open`` after a failed run.

    Uses a fresh session (the failed one may be unusable) and never raises.
    """
    try:
        async with factory() as session:
            ticket = await session.get(Ticket, ticket_id, populate_existing=True)
            if ticket is not None and ticket.status is TicketStatus.INVESTIGATING:
                ticket.status = TicketStatus.OPEN
                ticket.analysis = None
                await session.commit()
    except Exception:
        logger.exception("No se pudo devolver el ticket %s al estado open", ticket_id)


async def process_ticket_with_ai(
    ticket_id: UUID,
    graph: Any | None = None,
    session_factory: Any | None = None,
    ws_manager: ConnectionManager | None = None,
) -> None:
    """Run the ticket triage and investigation, emit the reasoning and persist the result.

    Lifecycle: ``open`` -> ``investigating`` (graph starts) -> ``escalated`` with the final
    severity and the root-cause analysis (graph succeeds). On failure the ticket returns to
    ``open`` without analysis. Runs as a background task, so it opens its own session and
    never propagates exceptions.

    Args:
        ticket_id: ticket to process.
        graph: injectable compiled graph (defaults to ``compiled_graph``).
        session_factory: injectable session factory (defaults to the environment's).
        ws_manager: injectable WebSocket manager (defaults to the global one).
    """
    factory = session_factory or get_session_factory()
    manager = ws_manager or default_manager
    try:
        async with factory() as session:
            ticket = await session.get(Ticket, ticket_id)
            if ticket is None:
                logger.warning("Ticket %s no encontrado; se omite el triaje", ticket_id)
                return

            description = ticket.description
            ticket.status = TicketStatus.INVESTIGATING
            await session.commit()

            active_graph = graph or _load_compiled_graph()
            await _emit(manager, ticket_id, "gateway", "Iniciando triaje")

            state: dict[str, Any] = {}
            async for chunk in active_graph.astream(
                {"ticket_id": str(ticket_id), "description": description},
                stream_mode="updates",
            ):
                for node, update in chunk.items():
                    state.update(update)
                    await _emit(manager, ticket_id, node, _describe_update(node, update))

            await _emit(manager, ticket_id, "database", "Actualizando base de datos")
            # Re-read: the ticket may have been deleted while the agents were running.
            ticket = await session.get(Ticket, ticket_id, populate_existing=True)
            if ticket is None:
                logger.warning("Ticket %s eliminado durante el triaje; se descarta", ticket_id)
                return
            ticket.severity = TicketSeverity(state["severity"])
            ticket.analysis = state.get("analysis")
            ticket.status = TicketStatus.ESCALATED
            await session.commit()
            logger.info(
                "Ticket %s procesado: severity=%s status=%s",
                ticket_id,
                ticket.severity.value,
                ticket.status.value,
            )
    except Exception:
        logger.exception("Falló el procesamiento con IA del ticket %s", ticket_id)
        await _revert_to_open(factory, ticket_id)
        await _emit(manager, ticket_id, "error", "El procesamiento con IA falló")
