"""Pydantic schemas of the API Gateway."""

from datetime import datetime
from enum import Enum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class TicketSeverity(str, Enum):
    """Allowed severity levels for a ticket."""

    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"


class TicketStatus(str, Enum):
    """Lifecycle states of a ticket."""

    OPEN = "open"
    INVESTIGATING = "investigating"
    PENDING_APPROVAL = "pending_approval"
    ESCALATED = "escalated"
    RESOLVED = "resolved"


class TicketCreate(BaseModel):
    """Input payload to create a ticket."""

    model_config = ConfigDict(str_strip_whitespace=True)

    title: str = Field(min_length=1, strict=True)
    description: str = Field(min_length=1, strict=True)
    severity: TicketSeverity


class TicketRead(TicketCreate):
    """Ticket returned by the API, with the server-generated fields."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    status: TicketStatus
    analysis: str | None = None
    created_at: datetime
    updated_at: datetime


class HealthResponse(BaseModel):
    """Health endpoint response."""

    status: str
    service: str


class TicketUpdate(BaseModel):
    """Partial payload to update a ticket (all fields optional)."""

    model_config = ConfigDict(str_strip_whitespace=True)

    title: str | None = Field(default=None, min_length=1, strict=True)
    description: str | None = Field(default=None, min_length=1, strict=True)
    severity: TicketSeverity | None = None
    status: TicketStatus | None = None
    analysis: str | None = Field(default=None, strict=True)


class LoginRequest(BaseModel):
    """Credentials posted to the login endpoint (length-bounded to cap hashing work)."""

    username: str = Field(min_length=1, max_length=64, strict=True)
    password: str = Field(min_length=1, max_length=256, strict=True)


class TokenResponse(BaseModel):
    """Access token issued by a successful login."""

    access_token: str
    token_type: str = "bearer"  # noqa: S105 - OAuth2 token type, not a credential
    expires_in: int
