"""The FastAPI app."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from starlette.exceptions import HTTPException as StarletteHTTPException

from backend import bootstrap, config, events, simulate, spa
from backend.adapters.queue_base import QueueError
from backend.ai import runtime
from backend.ai.asr import (
    ASR_UNAVAILABLE_AR,
    ASR_UNAVAILABLE_EN,
    AsrBadAudio,
    AsrFailed,
    AsrUnavailable,
)
from backend.ai.handoff import HandoffError
from backend.ai.session import SessionError
from backend.deps import ApiError
from backend.queue_engine import SqliteQueueEngine
from backend.routers import auth, centres, demo, staff, streams, visits

logger = logging.getLogger(__name__)

EXPIRY_INTERVAL_SEC = 30
SIMULATE_INTERVAL_SEC = 60

_QUEUE_ERROR_STATUS = {
    "ticket_not_found": 404,
    "ticket_expired": 410,
    "invalid_transition": 409,
    "visit_not_eligible": 409,
    "visit_has_live_ticket": 409,
    "counter_busy": 409,
}
_SESSION_ERRORS = {
    "visit_not_found": (404, "No visit has this ID."),
    "invalid_text": (422, "The message is empty or not valid text."),
    "visit_not_in_intake": (409, "This visit is past the chat stage."),
    "visit_not_deflected": (409, "This visit was not sent to the refill route."),
}
_HANDOFF_ERRORS = {
    "no_intake": (409, "This visit has no intake yet."),
    "no_patient": (404, "This visit has no patient record."),
}
_HTTP_ERROR_CODES = {404: "not_found", 405: "method_not_allowed"}


async def _expiry_loop(engine: SqliteQueueEngine) -> None:
    """The background half of the reservation expiry; the engine also checks lazily."""
    while True:
        await asyncio.sleep(EXPIRY_INTERVAL_SEC)
        try:
            await asyncio.to_thread(engine.expire_due)
        except Exception:
            logger.exception("reservation expiry pass failed")


async def _simulator_loop(engine: SqliteQueueEngine) -> None:
    """Keeps the other centres' queues moving while SIMULATE_LOAD is on."""
    while True:
        await asyncio.sleep(SIMULATE_INTERVAL_SEC)
        try:
            await asyncio.to_thread(simulate.tick, engine)
        except Exception:
            logger.exception("simulated load tick failed")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    load_dotenv()
    events.bus.bind_loop(asyncio.get_running_loop())
    bootstrap.startup()
    app.state.engine = SqliteQueueEngine(publish=events.bus.publish)
    app.state.ai = runtime.build_runtime()
    logger.info("AI mode: %s", app.state.ai.mode)
    tasks = [asyncio.create_task(_expiry_loop(app.state.engine))]
    if config.simulate_load():
        tasks.append(asyncio.create_task(_simulator_loop(app.state.engine)))
    try:
        yield
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


app = FastAPI(title="Dawri", lifespan=lifespan)

app.include_router(auth.router)
app.include_router(streams.router)
app.include_router(visits.router)
app.include_router(centres.router)
app.include_router(staff.router)
app.include_router(demo.router)


def _error(status_code: int, code: str, message: str, **extra: object) -> JSONResponse:
    return JSONResponse(
        status_code=status_code, content={"error": code, "message": message, **extra}
    )


@app.exception_handler(ApiError)
async def api_error(request: Request, exc: ApiError) -> JSONResponse:
    return _error(exc.status_code, exc.code, exc.message, **exc.extra)


@app.exception_handler(QueueError)
async def queue_error(request: Request, exc: QueueError) -> JSONResponse:
    return _error(_QUEUE_ERROR_STATUS.get(exc.code, 500), exc.code, str(exc))


@app.exception_handler(RequestValidationError)
async def invalid_request(request: Request, exc: RequestValidationError) -> JSONResponse:
    # Never the default body: it echoes input, which may hold patient text, and a
    # NaN in that echo crashes the JSON renderer into a 500.
    return _error(422, "invalid_request", "The request body or parameters are not valid.")


@app.exception_handler(SessionError)
async def session_error(request: Request, exc: SessionError) -> JSONResponse:
    status_code, message = _SESSION_ERRORS.get(exc.code, (400, str(exc)))
    return _error(status_code, exc.code, message)


@app.exception_handler(HandoffError)
async def handoff_error(request: Request, exc: HandoffError) -> JSONResponse:
    status_code, message = _HANDOFF_ERRORS.get(exc.code, (400, str(exc)))
    return _error(status_code, exc.code, message)


@app.exception_handler(AsrUnavailable)
async def asr_unavailable(request: Request, exc: AsrUnavailable) -> JSONResponse:
    return _error(503, "asr_unavailable", ASR_UNAVAILABLE_EN, message_ar=ASR_UNAVAILABLE_AR)


@app.exception_handler(AsrBadAudio)
async def asr_bad_audio(request: Request, exc: AsrBadAudio) -> JSONResponse:
    return _error(400, "bad_audio", str(exc))


@app.exception_handler(AsrFailed)
async def asr_failed(request: Request, exc: AsrFailed) -> JSONResponse:
    return _error(502, "asr_failed", "Voice failed. Please type your message.")


@app.exception_handler(StarletteHTTPException)
async def http_error(request: Request, exc: StarletteHTTPException) -> Response:
    # Not a catch-all route: routes added after startup must still win over the SPA.
    path = request.scope["path"]
    if exc.status_code == 404 and request.method in ("GET", "HEAD"):
        if not path.startswith("/api"):
            return spa.serve(path)
    code = _HTTP_ERROR_CODES.get(exc.status_code, "http_error")
    response = _error(exc.status_code, code, str(exc.detail))
    response.headers.update(exc.headers or {})
    return response


@app.exception_handler(Exception)
async def unexpected_error(request: Request, exc: Exception) -> JSONResponse:
    return _error(500, "internal_error", "Something went wrong on our side.")


@app.get("/api/health")
def health(request: Request) -> dict:
    return {
        "status": "ok",
        "ai_mode": request.app.state.ai.mode,
        "simulate_load": config.simulate_load(),
    }
