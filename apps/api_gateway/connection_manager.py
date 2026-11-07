"""Management of active WebSocket connections."""

import logging

from fastapi import WebSocket

logger = logging.getLogger(__name__)


class ConnectionManager:
    """Keep track of active WebSocket connections and allow sending them messages."""

    def __init__(self) -> None:
        self.active_connections: list[WebSocket] = []

    async def connect(self, websocket: WebSocket) -> None:
        """Accept the connection and register it."""
        await websocket.accept()
        self.register(websocket)

    def register(self, websocket: WebSocket) -> None:
        """Register an already accepted connection (used once it has authenticated)."""
        self.active_connections.append(websocket)
        logger.info("WebSocket conectado (activas=%d)", len(self.active_connections))

    def disconnect(self, websocket: WebSocket) -> None:
        """Remove the connection; idempotent."""
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)
            logger.info("WebSocket desconectado (activas=%d)", len(self.active_connections))

    async def send_personal_message(self, message: str, websocket: WebSocket) -> None:
        """Send a message to a specific connection."""
        await websocket.send_text(message)

    async def broadcast(self, message: str) -> None:
        """Send a message to all connections, dropping broken ones."""
        for connection in list(self.active_connections):
            try:
                await connection.send_text(message)
            except Exception:  # dropped connection: cleaned up without affecting the rest
                logger.warning("Failed to send; dropping the connection")
                self.disconnect(connection)


manager = ConnectionManager()
