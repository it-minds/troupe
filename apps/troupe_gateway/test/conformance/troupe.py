"""A Troupe protocol client in the Python standard library and nothing else.

This exists to keep the protocol honest. Troupe's own TUI is a client with no
private access, but that is a claim about Elixir code; this is the same claim
checked from outside the runtime, in a language with none of the conveniences.
If a third-party client cannot do it with a socket and ``json``, the protocol is
wrong.

It is also a worked example. Every method here maps to something in
``PROTOCOL.md``; nothing here needs the Troupe source.

    from troupe import Troupe

    with Troupe.connect_unix("/run/user/1000/troupe/daemon.sock") as client:
        fleet = client.call("fleet.get")
        client.subscribe("session:" + session_id, from_seq=0)
        for envelope in client.events(timeout=30):
            ...
"""

from __future__ import annotations

import json
import os
import socket
import time
import uuid
from collections import deque
from typing import Any, Iterator, Optional

PROTOCOL_VERSION = "1"


class TroupeError(Exception):
    """A JSON-RPC error from the server. ``message`` is a stable token, not prose."""

    def __init__(self, error: dict):
        self.code = error.get("code")
        self.message = error.get("message")
        self.data = error.get("data")
        super().__init__(f"{self.message} ({self.code}): {self.data}")


class Troupe:
    """One connection. Not thread-safe: give each thread its own."""

    def __init__(self, sock: socket.socket):
        self._sock = sock
        self._buffer = b""
        self._next_id = 1
        # Events that arrived while we were waiting for a response. They are not
        # ordered relative to responses on the wire, and dropping them would lose
        # part of a replay.
        self._pending: deque = deque()
        self.server_info: dict = {}
        self.scopes: list = []
        self.principal: dict = {}

    # -- connecting ---------------------------------------------------------

    @classmethod
    def connect_unix(cls, path: str, **kwargs) -> "Troupe":
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)
        return cls._handshake(sock, **kwargs)

    @classmethod
    def connect_tcp(cls, host: str, port: int, token: Optional[str] = None, **kwargs) -> "Troupe":
        sock = socket.create_connection((host, port))
        return cls._handshake(sock, token=token, **kwargs)

    @classmethod
    def _handshake(
        cls,
        sock: socket.socket,
        token: Optional[str] = None,
        name: str = "python-reference",
        version: str = "1",
        capabilities: Optional[dict] = None,
    ) -> "Troupe":
        client = cls(sock)
        params: dict[str, Any] = {
            "protocol_version": PROTOCOL_VERSION,
            "client_info": {"name": name, "version": version},
            "capabilities": capabilities or {},
        }
        if token:
            params["auth"] = {"token": token}

        result = client.call("initialize", params)
        client.server_info = result.get("server_info", {})
        client.scopes = result.get("scopes", [])
        client.principal = result.get("principal", {})
        return client

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass

    def __enter__(self) -> "Troupe":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    # -- commands -----------------------------------------------------------

    @staticmethod
    def command_id() -> str:
        """A fresh id. Reuse one only to retry the *same* command."""
        return "c-" + uuid.uuid4().hex[:16]

    def call(self, method: str, params: Optional[dict] = None, timeout: float = 30.0) -> dict:
        """Send a request and wait for its acknowledgement.

        The acknowledgement is not the effect: ``input.send`` returns ``accepted``
        and what the agent does about it arrives as events.
        """
        request_id = self._next_id
        self._next_id += 1
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})

        deadline = time.monotonic() + timeout
        while True:
            message = self._read_message(deadline - time.monotonic())
            if message.get("id") == request_id:
                if "error" in message:
                    raise TroupeError(message["error"])
                return message.get("result", {})
            self._queue(message)

    def subscribe(self, topic: str, level: str = "detail", from_seq: Optional[int] = None) -> dict:
        params = {"command_id": self.command_id(), "topic": topic, "level": level}
        if from_seq is not None:
            params["from_seq"] = from_seq
        return self.call("subscribe", params)

    def unsubscribe(self, subscription_id: str) -> dict:
        return self.call("unsubscribe", {"subscription_id": subscription_id})

    def send_input(self, session_id: str, text: str) -> dict:
        return self.call(
            "input.send",
            {"command_id": self.command_id(), "session_id": session_id, "text": text},
        )

    def respond_to_approval(self, session_id: str, call_id: str, decision: str) -> dict:
        return self.call(
            "approval.respond",
            {
                "command_id": self.command_id(),
                "session_id": session_id,
                "call_id": call_id,
                "decision": decision,
            },
        )

    # -- events -------------------------------------------------------------

    def events(self, timeout: float = 30.0) -> Iterator[dict]:
        """Yield ``{"topic", "session_id", "event"}`` envelopes until ``timeout``.

        A ``resync_required`` notification is yielded as
        ``{"resync": {...}}`` rather than raised: only the caller knows the last
        ``seq`` it actually *processed*, so only the caller can re-subscribe
        correctly.
        """
        deadline = time.monotonic() + timeout
        while True:
            if self._pending:
                yield self._pending.popleft()
                continue

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return

            message = self._read_message(remaining)
            queued = self._as_event(message)
            if queued is not None:
                yield queued

    def _queue(self, message: dict) -> None:
        event = self._as_event(message)
        if event is not None:
            self._pending.append(event)

    @staticmethod
    def _as_event(message: dict) -> Optional[dict]:
        method = message.get("method")
        if method == "event":
            return message.get("params", {})
        if method == "resync_required":
            return {"resync": message.get("params", {})}
        return None

    # -- framing ------------------------------------------------------------
    #
    # Newline-delimited JSON: one message per line, no length prefix, no batching.

    def _send(self, message: dict) -> None:
        self._sock.sendall(json.dumps(message).encode("utf-8") + b"\n")

    def _read_message(self, timeout: float) -> dict:
        deadline = time.monotonic() + max(timeout, 0.0)
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for a message")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("the daemon closed the connection")
            self._buffer += chunk

        line, self._buffer = self._buffer.split(b"\n", 1)
        return json.loads(line)


def default_socket_path() -> str:
    """Where a local daemon listens, per ``PROTOCOL.md`` §2."""
    base = os.environ.get("XDG_RUNTIME_DIR") or os.path.expanduser("~/.troupe/run")
    return os.path.join(base, "troupe", "daemon.sock")
