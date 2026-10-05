"""Opt-in loopback target for a trusted local HTTPS tunnel, never a studio proxy."""
import ipaddress
import re
import secrets

from starlette.responses import JSONResponse
from .store import digest


_ID = r"[A-Za-z0-9][A-Za-z0-9_:-]{0,255}"
_ROUTES = (
    ("GET", r"/v1/(health|engines|voices|books|jobs|legacy-recordings|pronunciations)"),
    ("POST", r"/v1/(pairings|voices|books|jobs|projects/import)"),
    ("GET", rf"/v1/(pairings|voices|books|jobs|assets|analyses)/{_ID}"),
    ("DELETE", rf"/v1/(voices|books|jobs)/{_ID}"),
    ("PUT", r"/v1/pronunciations"),
    ("DELETE", r"/v1/devices/current"),
    ("GET", rf"/v1/books/{_ID}/(source|cover|cast)"),
    ("PUT", rf"/v1/books/{_ID}/cast"),
    ("POST", rf"/v1/books/{_ID}/analyze"),
    ("GET", rf"/v1/voices/{_ID}/reference"),
    ("POST", rf"/v1/jobs/{_ID}/(cancel|pause|resume|retry|export|align)"),
)
_ALLOWED = tuple((method, re.compile(path)) for method, path in _ROUTES)


class PhoneGateway:
    """Share the app without sharing its administrative peer identity or lifespan.

    The listener must bind only to loopback with Uvicorn proxy_headers=False.
    Its trusted local tunnel terminates public TLS and strips any external mount
    prefix. All callers downstream have a fixed *non-loopback* device identity.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "lifespan":
            # The main listener owns the single app/worker lifespan. Even an
            # accidentally enabled second lifespan must never start it again.
            while True:
                message = await receive()
                if message["type"] == "lifespan.startup":
                    await send({"type": "lifespan.startup.complete"})
                elif message["type"] == "lifespan.shutdown":
                    await send({"type": "lifespan.shutdown.complete"})
                    return
        if scope["type"] != "http":
            if scope["type"] == "websocket": await send({"type": "websocket.close", "code": 1008})
            return

        async def reject(status, detail):
            await JSONResponse({"detail": detail}, status_code=status)(scope, receive, send)

        peer = scope.get("client")
        try: local = bool(peer) and ipaddress.ip_address(peer[0]).is_loopback
        except ValueError: local = False
        if not local:
            return await reject(403, "The phone gateway accepts only the local HTTPS tunnel")
        headers = scope.get("headers", [])
        if any(name.lower() == b"origin" for name, _ in headers):
            return await reject(403, "Browser origins are not accepted by the phone gateway")
        path = scope.get("path", "")
        try: encoded = path.encode("ascii")
        except UnicodeEncodeError: encoded = None
        # Compare before routing, so escaped slashes, traversal and double
        # decoding cannot turn a rejected public path into a private app route.
        if encoded is None or scope.get("raw_path", encoded) != encoded or not any(
            method == scope["method"] and pattern.fullmatch(path) for method, pattern in _ALLOWED
        ):
            return await reject(404, "Phone API route not found")
        public = path == "/v1/health" or path == "/v1/pairings" or path.startswith("/v1/pairings/")
        if not public:
            # Authenticate before FastAPI can parse/spool a protected upload.
            # Admin credentials have no meaning on this listener, even if leaked.
            authorizations = [value for name, value in headers if name.lower() == b"authorization"]
            value = authorizations[0] if len(authorizations) == 1 else b""
            token = value[7:].decode("latin-1") if value.startswith(b"Bearer ") else ""
            device = None
            if token and not secrets.compare_digest(token.encode(), self.app.state.config.admin_token.encode()):
                with self.app.state.store.db() as db:
                    device = db.execute("SELECT id FROM devices WHERE token_hash=?", (digest(token),)).fetchone()
            if not device:
                return await reject(401, "Pair this device before using the phone API")
        forwarded = dict(scope)
        forwarded.update(client=("203.0.113.1", 0), scheme="https", server=("phone-gateway.invalid", 443), root_path="")
        forwarded["headers"] = [(name, value) for name, value in headers if name.lower() not in {
            b"host", b"forwarded", b"x-real-ip", b"x-original-url", b"x-rewrite-url"
        } and not name.lower().startswith(b"x-forwarded-")]
        forwarded["headers"].append((b"host", b"phone-gateway.invalid"))
        # Preserve receive/send directly: uploads, range responses and downloads
        # stay streaming, with no gateway body buffering or credential rewriting.
        await self.app(forwarded, receive, send)
