"""Entry point of the AutoOps API Gateway (FastAPI)."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from apps.api_gateway.config import get_cors_allowed_origins
from apps.api_gateway.routers import auth, health, tickets, ws


def create_app() -> FastAPI:
    """Build the FastAPI application with its middleware.

    A factory is used so the CORS origins are read from the environment at
    app creation time (useful for tests and for startup).
    """
    application = FastAPI(title="AutoOps API Gateway", version="0.1.0")

    application.add_middleware(
        CORSMiddleware,
        allow_origins=get_cors_allowed_origins(),
        allow_methods=["*"],
        allow_headers=["*"],
    )
    application.include_router(health.router)
    application.include_router(auth.router)
    application.include_router(tickets.router)
    application.include_router(ws.router)
    return application


app = create_app()
