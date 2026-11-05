"""In-process event bus and SSE helpers.

Events are small notifications; clients refetch state when one arrives.
publish() is safe from any thread, including FastAPI's threadpool. The
subscriber registry lives on the event loop thread and is never touched from
anywhere else while that loop is alive.
"""

from __future__ import annotations

import asyncio
import json
import threading
from collections.abc import AsyncIterator


def counter_channel(counter_id: str) -> str:
    return f"counter:{counter_id}"


def visit_channel(visit_id: str) -> str:
    return f"visit:{visit_id}"


def display_channel(centre_id: str) -> str:
    return f"display:{centre_id}"


def sse_format(event: dict) -> str:
    payload = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
    return f"data: {payload}\n\n"


class Subscription:
    """One consumer's queue. Create it with EventBus.subscribe()."""

    def __init__(self, bus: EventBus, channels: frozenset[str], queue_size: int) -> None:
        self.channels = channels
        self.queue: asyncio.Queue[dict] = asyncio.Queue(maxsize=queue_size)
        self._bus = bus
        self._closed = False

    async def get(self) -> dict:
        return await self.queue.get()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._bus._remove(self)

    def __enter__(self) -> Subscription:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()


class EventBus:
    def __init__(self, queue_size: int = 256) -> None:
        self.dropped = 0
        self._queue_size = queue_size
        self._loop: asyncio.AbstractEventLoop | None = None
        self._subs: dict[str, set[Subscription]] = {}
        self._dropped_lock = threading.Lock()

    def bind_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        """Set the loop that delivers events. Call it on that loop's thread.

        Rebinding forgets subscribers of the previous loop: their queues
        belong to it, and waking a getter on a closed loop would raise.
        """
        if self._loop is not None and self._loop is not loop:
            self._subs.clear()
        self._loop = loop

    def publish(self, channel: str, event: dict) -> None:
        """Queue delivery from any thread. Never blocks or raises."""
        loop = self._loop
        if loop is None or loop.is_closed():
            self._count_drop()
            return
        try:
            loop.call_soon_threadsafe(self._deliver, channel, event)
        except RuntimeError:  # The loop closed after the check above.
            self._count_drop()

    def subscribe(self, *channels: str) -> Subscription:
        """Register a subscriber. Must be called on the loop thread."""
        if self._loop is not None and not self._on_loop():
            raise RuntimeError("subscribe must be called on the bound loop's thread")
        sub = Subscription(self, frozenset(channels), self._queue_size)
        for channel in sub.channels:
            self._subs.setdefault(channel, set()).add(sub)
        return sub

    def _deliver(self, channel: str, event: dict) -> None:
        for sub in self._subs.get(channel, ()):
            try:
                sub.queue.put_nowait(event)
            except asyncio.QueueFull:
                sub.queue.get_nowait()
                sub.queue.put_nowait(event)
                self._count_drop()

    def _remove(self, sub: Subscription) -> None:
        loop = self._loop
        if loop is None or loop.is_closed() or self._on_loop():
            self._discard(sub)
            return
        try:
            loop.call_soon_threadsafe(self._discard, sub)
        except RuntimeError:  # The loop closed, so no thread owns the registry.
            self._discard(sub)

    def _discard(self, sub: Subscription) -> None:
        for channel in sub.channels:
            subs = self._subs.get(channel)
            if subs is None:
                continue
            subs.discard(sub)
            if not subs:  # Visit channels are per visit, so do not keep them.
                del self._subs[channel]

    def _on_loop(self) -> bool:
        try:
            return asyncio.get_running_loop() is self._loop
        except RuntimeError:
            return False

    def _count_drop(self) -> None:
        with self._dropped_lock:
            self.dropped += 1


async def sse_stream(sub: Subscription, heartbeat: float = 15.0) -> AsyncIterator[str]:
    """Yield SSE text for one client and unsubscribe when it goes away."""
    try:
        yield ": connected\n\n"
        while True:
            try:
                event = await asyncio.wait_for(sub.get(), heartbeat)
            except TimeoutError:
                yield ": heartbeat\n\n"
            else:
                yield sse_format(event)
    finally:
        sub.close()


bus = EventBus()
