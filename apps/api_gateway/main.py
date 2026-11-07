"""Entry point of the AutoOps API Gateway (FastAPI)."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from apps.api_gateway.config import get_cors_allowed_origins, get_jwt_secret
from apps.api_gateway.routers import auth, health, tickets, ws


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    """Fail fast at startup when JWT_SECRET is missing or too short."""
    get_jwt_secret()
    yield


def create_app() -> FastAPI:
    """Build the FastAPI application with its middleware.

    A factory is used so the CORS origins are read from the environment at
    app creation time (useful for tests and for startup).
    """
    application = FastAPI(title="AutoOps API Gateway", version="0.1.0", lifespan=lifespan)

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
