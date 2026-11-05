from __future__ import annotations

import asyncio
import threading

import pytest

from backend.events import (
    EventBus,
    bus as module_bus,
    counter_channel,
    display_channel,
    sse_format,
    sse_stream,
    visit_channel,
)

TIMEOUT = 2.0


def bound_bus(queue_size: int = 256) -> EventBus:
    bus = EventBus(queue_size=queue_size)
    bus.bind_loop(asyncio.get_running_loop())
    return bus


async def delivered() -> None:
    """Let delivery callbacks that are already scheduled run."""
    await asyncio.sleep(0)


async def next_event(sub) -> dict:
    return await asyncio.wait_for(sub.get(), TIMEOUT)


def test_channel_names():
    assert counter_channel("C-WAKRA-T1") == "counter:C-WAKRA-T1"
    assert visit_channel("V123") == "visit:V123"
    assert display_channel("C-WAKRA") == "display:C-WAKRA"


def test_module_singleton():
    assert isinstance(module_bus, EventBus)


def test_publish_from_real_thread_reaches_subscriber():
    async def run():
        bus = bound_bus()
        seen = {}

        def worker():
            seen["thread"] = threading.get_ident()
            bus.publish("visit:V1", {"type": "ticket.called"})

        with bus.subscribe("visit:V1") as sub:
            thread = threading.Thread(target=worker)
            thread.start()
            event = await next_event(sub)
            thread.join()

        assert event == {"type": "ticket.called"}
        assert seen["thread"] != threading.get_ident()
        assert bus.dropped == 0

    asyncio.run(run())


def test_two_subscribers_receive_and_other_channel_does_not():
    async def run():
        bus = bound_bus()
        first = bus.subscribe("counter:A")
        second = bus.subscribe("counter:A")
        other = bus.subscribe("counter:B")

        bus.publish("counter:A", {"n": 1})

        assert await next_event(first) == {"n": 1}
        assert await next_event(second) == {"n": 1}
        assert other.queue.empty()

    asyncio.run(run())


def test_subscription_on_two_channels_receives_both():
    async def run():
        bus = bound_bus()
        sub = bus.subscribe("counter:A", "display:C")

        bus.publish("counter:A", {"n": 1})
        bus.publish("display:C", {"n": 2})

        assert await next_event(sub) == {"n": 1}
        assert await next_event(sub) == {"n": 2}

    asyncio.run(run())


def test_publish_without_bound_loop_is_a_counted_noop():
    bus = EventBus()
    bus.publish("visit:V1", {"n": 1})
    assert bus.dropped == 1


def test_publish_after_loop_closed_is_a_counted_noop():
    bus = EventBus()
    loop = asyncio.new_event_loop()
    bus.bind_loop(loop)
    loop.close()

    bus.publish("visit:V1", {"n": 1})

    assert bus.dropped == 1


def test_publish_when_loop_closes_after_the_check_is_a_counted_noop(monkeypatch):
    bus = EventBus()
    loop = asyncio.new_event_loop()
    bus.bind_loop(loop)
    monkeypatch.setattr(loop, "is_closed", lambda: False)

    def closed(*args):
        raise RuntimeError("Event loop is closed")

    monkeypatch.setattr(loop, "call_soon_threadsafe", closed)
    try:
        bus.publish("visit:V1", {"n": 1})
    finally:
        monkeypatch.undo()
        loop.close()

    assert bus.dropped == 1


def test_queue_overflow_drops_oldest_and_keeps_newest():
    async def run():
        bus = bound_bus(queue_size=2)
        sub = bus.subscribe("counter:A")

        for n in (1, 2, 3):
            bus.publish("counter:A", {"n": n})
        await delivered()

        assert sub.queue.get_nowait() == {"n": 2}
        assert sub.queue.get_nowait() == {"n": 3}
        assert sub.queue.empty()
        assert bus.dropped == 1

    asyncio.run(run())


def test_sse_stream_yields_connected_then_event_then_heartbeat():
    async def run():
        bus = bound_bus()
        sub = bus.subscribe("visit:V1")
        event = {"type": "ticket.called", "visit_id": "V1"}
        stream = sse_stream(sub, heartbeat=0.01)

        assert await anext(stream) == ": connected\n\n"
        bus.publish("visit:V1", event)
        assert await anext(stream) == sse_format(event)
        assert await anext(stream) == ": heartbeat\n\n"
        await stream.aclose()

    asyncio.run(run())


def test_closing_the_stream_unsubscribes():
    async def run():
        bus = bound_bus()
        sub = bus.subscribe("visit:V1")
        stream = sse_stream(sub, heartbeat=0.01)
        await anext(stream)

        await stream.aclose()
        bus.publish("visit:V1", {"n": 1})
        await delivered()

        assert sub.queue.empty()
        assert bus._subs == {}

    asyncio.run(run())


def test_cancelling_a_waiting_stream_unsubscribes():
    async def run():
        bus = bound_bus()
        sub = bus.subscribe("visit:V1")
        stream = sse_stream(sub, heartbeat=TIMEOUT)
        await anext(stream)

        task = asyncio.ensure_future(anext(stream))
        await delivered()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

        assert bus._subs == {}

    asyncio.run(run())


def test_sse_format_keeps_arabic_and_matches_vault_shape():
    event = {
        "type": "ticket.called",
        "visit_id": "V123",
        "ticket": "T-014",
        "counter": "Triage 1",
        "people_ahead": 0,
    }
    assert sse_format(event) == (
        'data: {"type":"ticket.called","visit_id":"V123","ticket":"T-014",'
        '"counter":"Triage 1","people_ahead":0}\n\n'
    )
    assert sse_format({"counter": "الفرز 1"}) == 'data: {"counter":"الفرز 1"}\n\n'


def test_close_is_idempotent_and_keeps_other_subscribers():
    async def run():
        bus = bound_bus()
        closed = bus.subscribe("counter:A")
        kept = bus.subscribe("counter:A")

        closed.close()
        closed.close()
        bus.publish("counter:A", {"n": 1})

        assert await next_event(kept) == {"n": 1}
        assert closed.queue.empty()
        assert bus.dropped == 0

    asyncio.run(run())


def test_close_from_another_thread_touches_registry_on_the_loop():
    async def run():
        bus = bound_bus()
        sub = bus.subscribe("counter:A")

        thread = threading.Thread(target=sub.close)
        thread.start()
        thread.join()

        assert sub in bus._subs["counter:A"]  # Scheduled, not yet run.
        await delivered()
        assert bus._subs == {}

    asyncio.run(run())


def test_subscribe_off_the_loop_thread_raises():
    async def run():
        bus = bound_bus()
        errors = []

        def worker():
            try:
                bus.subscribe("counter:A")
            except RuntimeError as exc:
                errors.append(exc)

        thread = threading.Thread(target=worker)
        thread.start()
        thread.join()

        assert len(errors) == 1
        assert bus._subs == {}

    asyncio.run(run())


def test_rebinding_forgets_subscribers_of_the_old_loop():
    bus = EventBus()

    async def old_app():
        bus.bind_loop(asyncio.get_running_loop())
        return bus.subscribe("counter:A")

    async def new_app():
        bus.bind_loop(asyncio.get_running_loop())
        sub = bus.subscribe("counter:A")
        bus.publish("counter:A", {"n": 1})
        assert await next_event(sub) == {"n": 1}

    old_sub = asyncio.run(old_app())
    asyncio.run(new_app())

    assert old_sub.queue.empty()
    assert bus.dropped == 0
