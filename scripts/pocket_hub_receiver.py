"""Small Pocket Hub-owned receiver; no models, library payloads or new credentials.

Run with the companion's bundled Python. Publish this loopback listener through
the existing HTTPS book mount; it forwards ordinary phone routes to port 8785.
Only the fixed Start command is handled while the companion is stopped.
"""
from __future__ import annotations

import argparse
import asyncio
from collections import OrderedDict
from contextlib import asynccontextmanager, closing
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time
import uuid

import httpx
from starlette.applications import Starlette
from starlette.background import BackgroundTask
from starlette.responses import JSONResponse, StreamingResponse
from bookpocket_companion.phone_gateway import _ALLOWED

START_PATH = "/v1/companion/start"
RECEIVER_HEALTH = "/v1/companion/receiver-health"
HOP = {b"connection", b"keep-alive", b"proxy-authenticate", b"proxy-authorization",
       b"te", b"trailer", b"transfer-encoding", b"upgrade"}


def device_for(database: Path, token: str) -> str | None:
    """Read the current pairing store, including revocations while the host is down."""
    if not token or len(token) > 512:
        return None
    with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)) as db:
        row = db.execute("SELECT id FROM devices WHERE token_hash=?",
                         (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
    return row[0] if row else None


async def start_in_hub(hub_exe: Path) -> None:
    # No shell, client-selected app, path, action, arguments or environment.
    def invoke():
        result = subprocess.run([str(hub_exe), "--control", "start", "bookopen"],
            cwd=hub_exe.parent, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=25,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if result.returncode:
            raise RuntimeError("Pocket Hub could not acknowledge the start request.")
    await asyncio.to_thread(invoke)


def create_receiver(database: Path, hub_exe: Path, *, starter=None, transport=None, clock=time.monotonic):
    starter = starter or (lambda: start_in_hub(hub_exe))
    rates: dict[str, tuple[float, int]] = {}
    requests: OrderedDict[tuple[str, str], float] = OrderedDict()
    start_lock = asyncio.Lock()
    client = httpx.AsyncClient(transport=transport, trust_env=False, follow_redirects=False,
                              timeout=httpx.Timeout(None, connect=3, pool=5))

    @asynccontextmanager
    async def lifespan(app):
        yield
        await client.aclose()

    app = Starlette(lifespan=lifespan)

    async def respond(scope, receive, send):
        async def reject(status, detail):
            await JSONResponse({"detail": detail}, status_code=status,
                headers={"Cache-Control": "no-store"})(scope, receive, send)

        peer = scope.get("client")
        try: local = bool(peer) and ipaddress.ip_address(peer[0]).is_loopback
        except ValueError: local = False
        if not local:
            return await reject(403, "The receiver accepts only the local HTTPS tunnel.")
        headers = scope.get("headers", [])
        if any(name.lower() == b"origin" for name, _ in headers):
            return await reject(403, "Browser origins are not accepted by this receiver.")
        path = scope.get("path", "")
        try: canonical = path.encode("ascii")
        except UnicodeEncodeError: canonical = None
        is_start = path == START_PATH and scope["method"] == "POST" and not scope.get("query_string")
        is_receiver_health = path == RECEIVER_HEALTH and scope["method"] == "GET" and not scope.get("query_string")
        if canonical is None or scope.get("raw_path", canonical) != canonical or not (
            is_start or is_receiver_health or any(method == scope["method"] and pattern.fullmatch(path) for method, pattern in _ALLOWED)
        ):
            return await reject(404, "Phone API route not found.")
        if is_receiver_health:
            return await JSONResponse({"receiver": "ready"}, headers={"Cache-Control": "no-store"})(scope, receive, send)
        public = path == "/v1/health" or path == "/v1/pairings" or path.startswith("/v1/pairings/")
        authorizations = [v for k, v in headers if k.lower() == b"authorization"]
        value = authorizations[0] if len(authorizations) == 1 else b""
        try: token = value[7:].decode("ascii") if value.startswith(b"Bearer ") else ""
        except UnicodeDecodeError: token = ""
        actor = None
        if not public:
            try: actor = await asyncio.to_thread(device_for, database, token)
            except sqlite3.Error:
                return await reject(503, "Saved PC pairing could not be checked. Try again shortly.")
            if not actor:
                return await reject(401, "Pair this device before starting or using the companion.")
        if is_start:
            # Authenticate before reading even a small control body.
            body = bytearray()
            while True:
                part = await receive()
                if part["type"] == "http.disconnect": return
                body.extend(part.get("body", b""))
                if len(body) > 1024: return await reject(413, "Start request is too large.")
                if not part.get("more_body"): break
            try:
                payload = json.loads(body)
                if not isinstance(payload, dict) or set(payload) != {"request_id"}:
                    raise ValueError()
                request_id = str(uuid.UUID(payload["request_id"]))
            except (ValueError, TypeError, KeyError, AttributeError):
                return await reject(400, "A start request must contain one UUID request_id.")
            async with start_lock:
                try:
                    if await asyncio.to_thread(device_for, database, token) != actor:
                        return await reject(401, "This device pairing was revoked.")
                except sqlite3.Error:
                    return await reject(503, "Saved PC pairing could not be checked. Try again shortly.")
                now = clock()
                for key, stamp in list(requests.items()):
                    if now - stamp >= 300: del requests[key]
                key = (actor, request_id)
                if key in requests:
                    return await JSONResponse({"status": "starting"}, headers={"Cache-Control": "no-store"})(scope, receive, send)
                for device, (stamp, _) in list(rates.items()):
                    if now - stamp >= 60: del rates[device]
                stamp, count = rates.get(actor, (now, 0))
                if count >= 8 or len(rates) >= 1024 and actor not in rates:
                    return await reject(429, "Too many start requests. Wait one minute before retrying.")
                rates[actor] = (stamp, count + 1)
                try: await starter()
                except (OSError, RuntimeError, subprocess.TimeoutExpired):
                    return await reject(503, "Pocket Hub could not start the companion. Check that Windows and Pocket Hub are running, then retry.")
                requests[key] = now
                while len(requests) > 1024: requests.popitem(last=False)
            # An acknowledgement does not establish authenticated readiness.
            return await JSONResponse({"status": "starting"}, headers={"Cache-Control": "no-store"})(scope, receive, send)

        from starlette.requests import Request
        request = Request(scope, receive)
        removed = HOP | {b"host"}
        forwarded = [(k, v) for k, v in headers if k.lower() not in removed]
        url = httpx.URL("http://127.0.0.1:8785").copy_with(raw_path=canonical + (
            b"?" + scope["query_string"] if scope.get("query_string") else b""))
        try:
            upstream = await client.send(client.build_request(scope["method"], url,
                headers=forwarded, content=request.stream()), stream=True)
        except httpx.HTTPError:
            return await reject(503, "PC companion is stopped or unavailable. Tap Start companion.")
        response = StreamingResponse(upstream.aiter_raw(), status_code=upstream.status_code,
                                     background=BackgroundTask(upstream.aclose))
        response.raw_headers = [(k, v) for k, v in upstream.headers.raw if k.lower() not in HOP]
        await response(scope, receive, send)

    class Receiver:
        async def __call__(self, scope, receive, send):
            if scope["type"] == "lifespan": return await app(scope, receive, send)
            if scope["type"] != "http":
                if scope["type"] == "websocket": await send({"type": "websocket.close", "code": 1008})
                return
            return await respond(scope, receive, send)
    return Receiver()


if __name__ == "__main__":
    import logging
    from logging.handlers import RotatingFileHandler
    import uvicorn
    parser = argparse.ArgumentParser()
    parser.add_argument("--hub-exe", required=True, type=Path)
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ["LOCALAPPDATA"]) / "BookPocketOpen")
    parser.add_argument("--port", type=int, default=8786)
    args = parser.parse_args()
    logs = args.data_dir / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(level=logging.WARNING, handlers=[RotatingFileHandler(
        logs / "start-receiver.log", maxBytes=2_000_000, backupCount=1, encoding="utf-8")])
    uvicorn.run(create_receiver(args.data_dir / "library.sqlite3", args.hub_exe),
                host="127.0.0.1", port=args.port, proxy_headers=False,
                access_log=False, log_config=None)
