"""Authenticated process recovery and actual streaming proxy boundaries."""
import asyncio
from contextlib import closing
import hashlib
from pathlib import Path
import runpy
import sqlite3
import uuid

import httpx
import pytest
from starlette.testclient import TestClient

receiver = runpy.run_path(str(Path(__file__).parents[1] / "scripts/pocket_hub_receiver.py"))
create_receiver = receiver["create_receiver"]
START = receiver["START_PATH"]
TOKEN = "test-only-receiver-device"


@pytest.fixture
def setup(tmp_path):
    db = tmp_path / "pairings.sqlite3"
    with closing(sqlite3.connect(db)) as conn, conn:
        conn.execute("CREATE TABLE devices(id TEXT PRIMARY KEY, token_hash TEXT UNIQUE)")
        conn.execute("INSERT INTO devices VALUES(?,?)", ("fixture-phone", hashlib.sha256(TOKEN.encode()).hexdigest()))
    calls = []
    async def start(): calls.append("bookopen")
    app = create_receiver(db, tmp_path / "PocketHub.exe", starter=start,
        transport=httpx.MockTransport(lambda request: httpx.Response(503)))
    with TestClient(app, client=("127.0.0.1", 1)) as client:
        yield db, calls, client, app


def authorized(client):
    client.headers["Authorization"] = "Bearer " + TOKEN
    return client


def test_offline_start_idempotent_and_revocation_is_live(setup):
    db, calls, client, _ = setup
    authorized(client)
    payload = {"request_id": str(uuid.uuid4())}
    assert client.post(START, json=payload).json() == {"status": "starting"}
    assert client.post(START, json=payload).status_code == 200
    assert calls == ["bookopen"]
    with closing(sqlite3.connect(db)) as conn, conn: conn.execute("DELETE FROM devices")
    assert client.post(START, json=payload).status_code == 401
    assert calls == ["bookopen"]


@pytest.mark.parametrize("token", ["", "Bearer invalid", "Bearer fixture-admin"])
def test_invalid_credential_cannot_start_or_proxy(setup, token):
    _, calls, client, _ = setup
    client.headers["Authorization"] = token
    assert client.post(START, json={"request_id": str(uuid.uuid4())}).status_code == 401
    assert client.get("/v1/engines").status_code == 401
    assert calls == []


@pytest.mark.parametrize("payload", [{}, {"action": "restart", "request_id": str(uuid.uuid4())},
    {"request_id": 123}, {"request_id": "wrong"}, ["start"]])
def test_no_client_selected_action_or_invalid_identity(setup, payload):
    _, calls, client, _ = setup
    assert authorized(client).post(START, json=payload).status_code == 400
    assert calls == []


def test_limits_before_dispatch_and_bounded_body(setup):
    _, calls, client, _ = setup
    authorized(client)
    assert client.post(START, content=b"x" * 1025).status_code == 413
    for _ in range(8): assert client.post(START, json={"request_id": str(uuid.uuid4())}).status_code == 200
    assert client.post(START, json={"request_id": str(uuid.uuid4())}).status_code == 429
    assert len(calls) == 8


def test_origin_remote_peer_and_noncanonical_control_rejected(setup):
    _, calls, client, app = setup
    authorized(client)
    assert client.post(START, headers={"Origin": "https://fixture.invalid"}, json={}).status_code == 403
    assert client.post(START + "?action=start", json={}).status_code == 404
    assert client.post("/v1/companion/%73tart", json={}).status_code == 404
    assert client.post("/v1/admin/connection", json={}).status_code == 404
    with TestClient(app, client=("198.51.100.1", 1)) as remote:
        assert remote.post(START, headers={"Authorization": "Bearer " + TOKEN}, json={}).status_code == 403
    assert calls == []


def test_unauthorized_request_does_not_read_body(setup):
    _, calls, _, app = setup
    messages = []
    async def receive(): raise AssertionError("Unauthorized body was consumed")
    async def send(message): messages.append(message)
    scope = {"type": "http", "method": "POST", "path": START, "raw_path": START.encode(),
        "client": ("127.0.0.1", 1), "headers": [], "query_string": b""}
    asyncio.run(app(scope, receive, send))
    assert messages[0]["status"] == 401 and not calls


def test_failed_hub_and_database_are_actionable_not_ready(tmp_path):
    db = tmp_path / "pairings.sqlite3"
    with closing(sqlite3.connect(db)) as conn, conn:
        conn.execute("CREATE TABLE devices(id TEXT, token_hash TEXT)")
        conn.execute("INSERT INTO devices VALUES(?,?)", ("phone", hashlib.sha256(TOKEN.encode()).hexdigest()))
    async def start(): raise RuntimeError("harmless injected failure")
    with TestClient(create_receiver(db, tmp_path / "PocketHub.exe", starter=start), client=("127.0.0.1", 1)) as client:
        response = authorized(client).post(START, json={"request_id": str(uuid.uuid4())})
        assert response.status_code == 503 and "Pocket Hub" in response.json()["detail"]
        db.unlink()
        assert client.post(START, json={"request_id": str(uuid.uuid4())}).status_code == 503
        assert not db.exists()  # Read-only authentication cannot recreate a missing store.


def test_proxy_preserves_upload_range_and_raw_response(tmp_path):
    db = tmp_path / "pairings.sqlite3"
    with closing(sqlite3.connect(db)) as conn, conn:
        conn.execute("CREATE TABLE devices(id TEXT, token_hash TEXT)")
        conn.execute("INSERT INTO devices VALUES(?,?)", ("phone", hashlib.sha256(TOKEN.encode()).hexdigest()))
    class Chunks(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield b"original-"
            yield b"fixture-bytes"
    seen = []
    async def target(request):
        seen.append((request.url, request.headers, await request.aread()))
        return httpx.Response(206, stream=Chunks(), headers={"Content-Range": "bytes 0-21/22", "X-Content-SHA256": "fixture"})
    app = create_receiver(db, tmp_path / "PocketHub.exe", transport=httpx.MockTransport(target))
    with TestClient(app, client=("127.0.0.1", 1)) as client:
        response = authorized(client).post("/v1/books", content=b"original-upload", headers={"Range": "bytes=0-21"})
        assert response.status_code == 206 and response.content == b"original-fixture-bytes"
        assert response.headers["Content-Range"] == "bytes 0-21/22"
        assert response.headers["X-Content-SHA256"] == "fixture"
        assert seen[0][0].host == "127.0.0.1" and seen[0][0].port == 8785
        assert seen[0][1]["Authorization"] == "Bearer " + TOKEN
        assert seen[0][1]["Range"] == "bytes=0-21" and seen[0][2] == b"original-upload"


def test_connection_refused_is_stopped_not_false_health(tmp_path):
    async def refused(request): raise httpx.ConnectError("harmless stopped target")
    app = create_receiver(tmp_path / "missing", tmp_path / "PocketHub.exe", transport=httpx.MockTransport(refused))
    with TestClient(app, client=("127.0.0.1", 1)) as client:
        response = client.get("/v1/health")
        assert response.status_code == 503 and "Start companion" in response.json()["detail"]
