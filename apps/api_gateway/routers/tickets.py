"""REST ticket endpoints backed by PostgreSQL."""

from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from apps.api_gateway.database import get_db_session
from apps.api_gateway.models import Ticket
from apps.api_gateway.schemas import (
    TicketCreate,
    TicketRead,
    TicketSeverity,
    TicketUpdate,
)
from apps.api_gateway.services.ai_service import process_ticket_with_ai

router = APIRouter(prefix="/api/v1/tickets", tags=["tickets"])


async def _get_ticket_or_404(session: AsyncSession, ticket_id: UUID) -> Ticket:
    ticket = await session.get(Ticket, ticket_id)
    if ticket is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Ticket not found"
        )
    return ticket


@router.post("", response_model=TicketRead, status_code=status.HTTP_201_CREATED)
async def create_ticket(
    payload: TicketCreate,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_db_session),
) -> Ticket:
    """Create the ticket with ``medium`` severity and enqueue AI triage.

    The real severity is assigned by the Triage Agent in the background; the
    response does not wait for the graph.
    """
    data = payload.model_dump(exclude={"severity"})
    ticket = Ticket(**data, severity=TicketSeverity.MEDIUM)
    session.add(ticket)
    await session.commit()
    await session.refresh(ticket)
    background_tasks.add_task(process_ticket_with_ai, ticket.id)
    return ticket


@router.get("", response_model=list[TicketRead])
async def list_tickets(session: AsyncSession = Depends(get_db_session)) -> list[Ticket]:
    """List tickets, most recent first."""
    result = await session.execute(select(Ticket).order_by(Ticket.created_at.desc()))
    return list(result.scalars().all())


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
async def delete_all_tickets(session: AsyncSession = Depends(get_db_session)) -> None:
    """Delete every ticket (irreversible); the dashboard asks for confirmation first."""
    await session.execute(delete(Ticket))
    await session.commit()


@router.delete("/{ticket_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_ticket(
    ticket_id: UUID, session: AsyncSession = Depends(get_db_session)
) -> None:
    """Delete one ticket (irreversible), or 404 if it does not exist."""
    ticket = await _get_ticket_or_404(session, ticket_id)
    await session.delete(ticket)
    await session.commit()


@router.get("/{ticket_id}", response_model=TicketRead)
async def get_ticket(
    ticket_id: UUID, session: AsyncSession = Depends(get_db_session)
) -> Ticket:
    """Return a ticket by ID, or 404 if it does not exist."""
    return await _get_ticket_or_404(session, ticket_id)


@router.patch("/{ticket_id}", response_model=TicketRead)
async def update_ticket(
    ticket_id: UUID,
    payload: TicketUpdate,
    session: AsyncSession = Depends(get_db_session),
) -> Ticket:
    """Partially update a ticket; only the submitted fields change."""
    ticket = await _get_ticket_or_404(session, ticket_id)
    for field, value in payload.model_dump(exclude_unset=True, exclude_none=True).items():
        setattr(ticket, field, value)
    await session.commit()
    await session.refresh(ticket)
    return ticket
