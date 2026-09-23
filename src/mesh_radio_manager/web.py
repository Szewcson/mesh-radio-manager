"""Opt-in, read-only diagnostics dashboard on a separate port."""

from __future__ import annotations

from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from typing import Any

from .assignments import load
from .diagnostics import report


class _Handler(BaseHTTPRequestHandler):
    server_version = "MeshRadioManager/0.1"

    def log_message(self, format: str, *args: Any) -> None:  # Avoid request data in system logs.
        return

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/api/status":
            self._send(200, json.dumps(report(), indent=2).encode(), "application/json; charset=utf-8")
            return
        if self.path == "/":
            body = b"""<!doctype html><meta charset=utf-8><title>Mesh Radio Manager</title>
<h1>Mesh Radio Manager</h1><p>Read-only diagnostics dashboard.</p><pre id=data>Loading...</pre>
<script>fetch('/api/status').then(r=>r.json()).then(x=>data.textContent=JSON.stringify(x,null,2)).catch(e=>data.textContent=e)</script>"""
            self._send(200, body, "text/html; charset=utf-8")
            return
        self._send(404, b"Not found\n", "text/plain; charset=utf-8")


def serve() -> None:
    config = load().get("web", {})
    host = str(config.get("host", "127.0.0.1"))
    port = int(config.get("port", 8001))
    if not 1 <= port <= 65535:
        raise ValueError("web port must be in 1..65535")
    server = ThreadingHTTPServer((host, port), _Handler)
    server.serve_forever()
