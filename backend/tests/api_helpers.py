"""Shared helpers for the HTTP tests."""

from __future__ import annotations

import queue
import socket
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

import httpx
import uvicorn
from fastapi import FastAPI
from fastapi.testclient import TestClient

FATIMA_QID = "DEMO-10001"
AHMED_QID = "DEMO-10002"
RAVI_QID = "DEMO-10003"

FATIMA_ANSWERS = ("عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا")
RAVI_TEXT = "Chest pain going to my left arm."
AHMED_TEXT = "I need my usual blood pressure tablets."

NURSE = "S-WAK-NURSE1"
DOCTOR2 = "S-WAK-DOC2"
PHARMACIST = "S-WAK-PHARM1"
DESK = "S-WAK-DESK1"


def patient_token(client: TestClient | httpx.Client, qid: str) -> str:
    response = client.post("/api/auth/verify", json={"qid": qid, "otp": "0000"})
    assert response.status_code == 200, response.text
    return response.json()["token"]


def staff_token(client: TestClient | httpx.Client, staff_id: str) -> str:
    response = client.post("/api/staff/login", json={"staff_id": staff_id})
    assert response.status_code == 200, response.text
    return response.json()["token"]


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def start_visit(client: TestClient, token: str, patient_id: str | None = None) -> str:
    """Open a visit with consent given. Returns the visit id."""
    body: dict = {"consent": True}
    if patient_id is not None:
        body["patient_id"] = patient_id
    response = client.post("/api/visits", json=body, headers=bearer(token))
    assert response.status_code in (200, 201), response.text
    return response.json()["visit_id"]


def say(client: TestClient, token: str, visit_id: str, *texts: str) -> dict:
    """Send each message in order. Returns the last reply's JSON."""
    last: dict = {}
    for text in texts:
        response = client.post(
            f"/api/visits/{visit_id}/chat", json={"text": text}, headers=bearer(token)
        )
        assert response.status_code == 200, response.text
        last = response.json()
    return last


@dataclass
class Live:
    base_url: str
    http: httpx.Client


def _stop(server: uvicorn.Server, thread: threading.Thread) -> None:
    server.should_exit = True
    thread.join(timeout=3)
    if thread.is_alive():  # A stream left open by a failed test blocks a clean exit.
        server.force_exit = True
        thread.join(timeout=3)


@contextmanager
def live_server(app: FastAPI) -> Iterator[Live]:
    """A real uvicorn on a free port: TestClient hangs on an infinite stream.

    The caller sets the environment first, as the `live_api` fixture does.
    """
    threads_before = set(threading.enumerate())
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, log_level="warning"))
    thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 5
        while not server.started and thread.is_alive() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.started

        base_url = f"http://127.0.0.1:{port}"
        with httpx.Client(base_url=base_url, trust_env=False, timeout=5) as http:
            yield Live(base_url, http)
    finally:
        _stop(server, thread)
        sock.close()

    assert not thread.is_alive()
    deadline = time.monotonic() + 2
    while set(threading.enumerate()) - threads_before and time.monotonic() < deadline:
        time.sleep(0.01)
    assert not set(threading.enumerate()) - threads_before


class StreamLines:
    """Lines from an open stream, read on their own thread."""

    def __init__(self) -> None:
        self.lines: queue.Queue[str] = queue.Queue()
        self.stop = threading.Event()

    def until(self, wanted: str, timeout: float = 5.0) -> list[str]:
        """Lines up to and including the first one containing `wanted`."""
        seen = []
        deadline = time.monotonic() + timeout
        while True:
            line = self.lines.get(timeout=max(deadline - time.monotonic(), 0.01))
            seen.append(line)
            if wanted in line:
                return seen


def _read_stream(stream: StreamLines, url: httpx.URL, headers: dict[str, str]) -> None:
    """HTTP/1.0 over a plain socket: no chunk framing, and a read can time out and resume."""
    head = [f"GET {url.raw_path.decode()} HTTP/1.0", f"Host: {url.netloc.decode()}"]
    head += [f"{name}: {value}" for name, value in headers.items()]
    with socket.create_connection((url.host, url.port), timeout=0.1) as sock:
        sock.sendall(("\r\n".join(head) + "\r\n\r\n").encode())
        pending = b""
        while not stream.stop.is_set():
            try:
                data = sock.recv(4096)
            except TimeoutError:
                continue
            if not data:
                return
            *complete, pending = (pending + data).split(b"\n")
            for line in complete:
                text = line.decode().rstrip("\r")
                if text.startswith("HTTP/1."):
                    text = f"status {text.split()[1]}"
                stream.lines.put(text)


@contextmanager
def open_stream(
    live: Live, path: str, token: str | None = None, headers: dict[str, str] | None = None
) -> Iterator[StreamLines]:
    """GET an SSE path with a reader thread. The first line is 'status <code>'."""
    stream = StreamLines()
    params = {} if token is None else {"token": token}
    url = httpx.URL(live.base_url + path, params=params)
    reader = threading.Thread(target=_read_stream, args=(stream, url, headers or {}), daemon=True)
    reader.start()
    try:
        yield stream
    finally:
        stream.stop.set()
        reader.join(timeout=3)
        assert not reader.is_alive()
