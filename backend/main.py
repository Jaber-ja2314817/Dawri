"""The FastAPI app."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from backend import bootstrap, config, events
from backend.adapters.queue_base import QueueError
from backend.ai import runtime
from backend.deps import ApiError
from backend.queue_engine import SqliteQueueEngine
from backend.routers import auth, streams

logger = logging.getLogger(__name__)

EXPIRY_INTERVAL_SEC = 30

_QUEUE_ERROR_STATUS = {
    "ticket_not_found": 404,
    "ticket_expired": 410,
    "invalid_transition": 409,
    "visit_not_eligible": 409,
    "visit_has_live_ticket": 409,
    "counter_busy": 409,
}


async def _expiry_loop(engine: SqliteQueueEngine) -> None:
    """The background half of the reservation expiry; the engine also checks lazily."""
    while True:
        await asyncio.sleep(EXPIRY_INTERVAL_SEC)
        try:
            await asyncio.to_thread(engine.expire_due)
        except Exception:
            logger.exception("reservation expiry pass failed")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    load_dotenv()
    events.bus.bind_loop(asyncio.get_running_loop())
    bootstrap.startup()
    app.state.engine = SqliteQueueEngine(publish=events.bus.publish)
    app.state.ai = runtime.build_runtime()
    logger.info("AI mode: %s", app.state.ai.mode)
    expiry = asyncio.create_task(_expiry_loop(app.state.engine))
    try:
        yield
    finally:
        expiry.cancel()
        await asyncio.gather(expiry, return_exceptions=True)


app = FastAPI(title="Dawri", lifespan=lifespan)

app.include_router(auth.router)
app.include_router(streams.router)


@app.exception_handler(ApiError)
async def api_error(request: Request, exc: ApiError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code, content={"error": exc.code, "message": exc.message}
    )


@app.exception_handler(QueueError)
async def queue_error(request: Request, exc: QueueError) -> JSONResponse:
    return JSONResponse(
        status_code=_QUEUE_ERROR_STATUS.get(exc.code, 500),
        content={"error": exc.code, "message": str(exc)},
    )


@app.get("/api/health")
def health(request: Request) -> dict:
    return {
        "status": "ok",
        "ai_mode": request.app.state.ai.mode,
        "simulate_load": config.simulate_load(),
    }
