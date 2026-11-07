"""Health endpoints of the API Gateway."""

from fastapi import APIRouter

from apps.api_gateway.schemas import HealthResponse

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse)
@router.get("/api/v1/health", response_model=HealthResponse)
def health() -> HealthResponse:
    """Report that the service is up (public, no database access).

    ``/api/v1/health`` is the one reachable through the proxy, which only routes ``/api`` and ``/ws``
    to the gateway; ``/health`` is the container healthcheck.
    """
    return HealthResponse(status="ok", service="api_gateway")
