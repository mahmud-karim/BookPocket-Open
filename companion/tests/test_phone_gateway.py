"""Public-tunnel boundary, using original text and isolated disposable state only."""
import asyncio
import json

import pytest
from fastapi.testclient import TestClient

from bookpocket_companion.app import create_app
from bookpocket_companion.cli import connection_config, save_connection_config
from bookpocket_companion.models import Config
from bookpocket_companion.phone_gateway import PhoneGateway
from bookpocket_companion.store import canonical, digest


@pytest.fixture
def gateway(tmp_path):
    app = create_app(Config(data_dir=tmp_path, admin_token="fixture-admin", dev=True), engines={}, start_worker=False)
    admin = TestClient(app, client=("127.0.0.1", 1000), headers={"Authorization": "Bearer fixture-admin"})
    wrapper = PhoneGateway(app)
    phone = TestClient(wrapper, client=("127.0.0.1", 1001))
    ticket = admin.post("/v1/admin/pairing-tickets").json()
    pending = phone.post("/v1/pairings", json={"code": ticket["code"], "device_name": "Original gateway fixture"}).json()
    assert admin.post(f"/v1/admin/pairings/{pending['id']}/approve").status_code == 200
    exchange = phone.get(f"/v1/pairings/{pending['id']}", headers={"Authorization": "Bearer " + pending["poll_token"]})
    assert exchange.status_code == 200
    phone.headers["Authorization"] = "Bearer " + exchange.json()["device_token"]
    yield app, admin, phone, wrapper
    admin.close()
    phone.close()


def test_pairing_shared_library_cast_and_revocation(gateway):
    app, admin, phone, wrapper = gateway
    assert wrapper.app is app
    assert phone.get("/v1/health").status_code == 200
    response = phone.post("/v1/books", files={"file": ("original.txt", "An original compass 🧭 passage.")})
    assert response.status_code == 200, response.text
    book = response.json()
    assert admin.get("/v1/books").json()["books"][0]["id"] == book["id"]
    assert phone.get(f"/v1/books/{book['id']}/source").content == "An original compass 🧭 passage.".encode()
    assert phone.get(f"/v1/books/{book['id']}/cast").status_code == 200
    assert phone.put(f"/v1/books/{book['id']}/cast", json={"characters": [], "assignments": []}).status_code == 200
    # Supported narration-only chapters need no analysis model.
    assert phone.post(f"/v1/books/{book['id']}/analyze", json={"allow_hosted": False}).status_code == 202
    assert phone.get(f"/v1/books/{book['id']}/analysis-status").status_code == 200
    assert phone.get("/v1/analyses/missing").json()["detail"] != "Phone API route not found"
    assert phone.delete("/v1/devices/current").status_code == 200
    assert phone.get("/v1/books").status_code == 401


def test_recording_alignment_deletion_and_pronunciations_are_protected_device_routes(gateway):
    _, _, phone, _ = gateway
    assert phone.put('/v1/pronunciations', json={'pronunciation_rules': [{'term': 'Kyon', 'replacement': 'Key on'}], 'expected_revision': 0}).status_code == 200
    assert phone.get('/v1/pronunciations').json()['revision'] == 1
    for method, path in [('post', '/v1/jobs/missing/align'), ('delete', '/v1/jobs/missing')]:
        response = getattr(phone, method)(path)
        assert response.status_code == 404 and response.json()['detail'] != 'Phone API route not found'
        assert getattr(phone, method)(path, headers={'Authorization': 'Bearer fixture-admin'}).status_code == 401
    assert phone.put('/v1/pronunciations', json={'pronunciation_rules': [], 'expected_revision': 1}, headers={'Authorization': 'Bearer fixture-admin'}).status_code == 401
    assert phone.post('/v1/voice-previews', json={'request_id': '862ab859-0207-4422-a7ea-6660577fef3b', 'voice_id': 'missing', 'text': 'Original preview.'}).status_code == 404
    assert phone.get('/v1/voice-previews/missing').json()['detail'] != 'Phone API route not found'
    assert phone.delete('/v1/voice-previews/missing').json()['detail'] != 'Phone API route not found'
    assert phone.get('/v1/voice-previews/missing', headers={'Authorization': 'Bearer fixture-admin'}).status_code == 401


@pytest.mark.parametrize("path", ["/", "/docs", "/redoc", "/openapi.json", "/v1/admin/connection", "/v1/admin/pairing-tickets", "/v1/admin/analyzer", "/v1/books/a/unknown", "/bookpocket/v1/health"])
def test_admin_and_nondevice_routes_blocked(gateway, path):
    _, _, phone, _ = gateway
    assert phone.get(path, headers={"Authorization": "Bearer fixture-admin"}).status_code == 404


def test_admin_secret_forwarded_headers_origins_and_remote_peers_denied(gateway):
    app, admin, phone, wrapper = gateway
    assert admin.get("/v1/books").status_code == 200
    for token in ["", "Bearer fixture-admin", "Bearer unknown"]:
        response = phone.get("/v1/books", headers={"Authorization": token, "Host": "localhost:8782", "Forwarded": "for=127.0.0.1;proto=https", "X-Forwarded-For": "127.0.0.1"})
        assert response.status_code == 401
    for origin in ["http://127.0.0.1:8782", "https://public.example", "null", ""]:
        assert phone.get("/v1/books", headers={"Origin": origin}).status_code == 403
    remote = TestClient(wrapper, client=("198.51.100.2", 2000), headers=phone.headers)
    assert remote.get("/v1/books", headers={"X-Forwarded-For": "127.0.0.1"}).status_code == 403


def invoke(wrapper, *, path, raw_path=None, method="GET", headers=(), receive=None):
    messages = []
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method,
             "scheme": "http", "path": path, "raw_path": raw_path if raw_path is not None else path.encode(),
             "root_path": "", "query_string": b"", "headers": list(headers), "client": ("127.0.0.1", 2000), "server": ("127.0.0.1", 8785)}
    async def absent_body():
        raise AssertionError("Rejected request must not read its body")
    async def send(message): messages.append(message)
    asyncio.run(wrapper(scope, receive or absent_body, send))
    return messages


@pytest.mark.parametrize("path,raw", [("/v1/health", b"/v1/%68ealth"), ("/v1/health", b"/v1%2fhealth"),
    ("/v1/books/../admin/connection", None), ("/v1//health", None), ("/v1\\admin\\connection", None),
    ("/v1/health/", None), ("/v1/books/%2e%2e", None), ("/v1/books/å", None), ("/v1/health\x00", None)])
def test_noncanonical_path_rejected_before_body(gateway, path, raw):
    assert invoke(gateway[3], path=path, raw_path=raw)[0]["status"] == 404


@pytest.mark.parametrize("path", ["/v1/books", "/v1/voices", "/v1/projects/import", "/v1/jobs"])
def test_unauthorized_upload_never_reads_body(gateway, path):
    for authorization in [b"", b"Bearer fixture-admin"]:
        messages = invoke(gateway[3], path=path, method="POST", headers=[(b"authorization", authorization), (b"content-type", b"multipart/form-data; boundary=fixture"), (b"content-length", b"10000000")])
        assert messages[0]["status"] == 401


def test_download_ranges_and_checksum_survive(gateway, tmp_path):
    app, _, phone, _ = gateway
    original = bytes(range(256)) * 4096
    file = tmp_path / "assets" / "original-fixture.wav"
    file.write_bytes(original)
    metadata = {"media_type": "audio/wav", "sha256": digest(original)}
    with app.state.store.db() as db:
        db.execute("INSERT INTO assets VALUES(?,?,?,?)", ("fixture", "fixture", canonical(metadata), str(file)))
    response = phone.get("/v1/assets/fixture", headers={"Range": "bytes=11-12345"})
    assert response.status_code == 206
    assert response.content == original[11:12346]
    assert response.headers["Content-Range"] == f"bytes 11-12345/{len(original)}"
    assert response.headers["X-Content-SHA256"] == digest(original)
    assert response.headers["ETag"] == '"' + digest(original) + '"'
    assert phone.get("/v1/assets/fixture").content == original


def test_streaming_scope_identity_and_single_lifespan(tmp_path, monkeypatch):
    app = create_app(Config(data_dir=tmp_path), engines={}, start_worker=True)
    starts, closes = [], []
    monkeypatch.setattr(app.state.worker, "start", lambda: starts.append(1))
    monkeypatch.setattr(app.state.worker, "close", lambda: closes.append(1))
    with TestClient(app, client=("127.0.0.1", 1)):
        with TestClient(PhoneGateway(app), client=("127.0.0.1", 2)) as phone:
            assert phone.get("/v1/health").status_code == 200
            assert starts == [1] and closes == []
        assert closes == []
    assert closes == [1]
    chunks = [{"type": "http.request", "body": b"first", "more_body": True}, {"type": "http.request", "body": b"second", "more_body": False}]
    async def receive(): return chunks.pop(0)
    async def streaming(scope, actual_receive, send):
        assert actual_receive is receive
        assert scope["client"][0] == "203.0.113.1" and scope["scheme"] == "https"
        assert scope["headers"] == [(b"range", b"bytes=0-5"), (b"host", b"phone-gateway.invalid")]
        await send({"type": "http.response.start", "status": 200, "headers": []})
        while True:
            part = await actual_receive()
            await send({"type": "http.response.body", "body": part["body"], "more_body": part["more_body"]})
            if not part["more_body"]: break
    messages = invoke(PhoneGateway(streaming), path="/v1/health", headers=[(b"range", b"bytes=0-5"), (b"host", b"spoof"), (b"forwarded", b"for=127.0.0.1"), (b"x-forwarded-host", b"localhost")], receive=receive)
    assert [part["body"] for part in messages[1:]] == [b"first", b"second"]


def test_explicit_connection_settings_persist_and_system_trust_omits_pin(tmp_path):
    initial = Config(data_dir=tmp_path, certificate_sha256="fixture-certificate")
    assert initial.phone_gateway_port is None and initial.public_tls_mode == "pinned"
    saved = {"ffmpeg": "fixture-ffmpeg", "unrelated_setting": "preserved"}
    configured = connection_config(initial, saved, public_url="https://public.example:10000/bookpocket", public_tls_mode="system", phone_gateway_port=8785)
    path = tmp_path / "config.json"
    save_connection_config(path, saved, configured)
    persisted = json.loads(path.read_text())
    assert persisted["unrelated_setting"] == "preserved"
    assert "admin_token" not in persisted and "certificate_sha256" not in persisted
    reconstructed = connection_config(initial, persisted)
    assert reconstructed.phone_gateway_port == 8785 and reconstructed.public_tls_mode == "system"
    assert reconstructed.public_url == configured.public_url
    assert connection_config(initial, persisted, phone_gateway_port=0).phone_gateway_port is None
    for value in [-1, 65536, 8782, 8783, True]:
        with pytest.raises(ValueError): connection_config(initial, {}, phone_gateway_port=value)
    for mode in ["pinned", "system"]:
        config = reconstructed.model_copy(update={"public_tls_mode": mode})
        app = create_app(config, engines={}, start_worker=False)
        client = TestClient(app, client=("127.0.0.1", 1), headers={"Authorization": "Bearer " + config.admin_token})
        response = client.get("/v1/admin/connection").json()
        assert ("certificate_sha256" in response) == (mode == "pinned")
        assert config.certificate_sha256 == "fixture-certificate"


def test_cli_gateway_shares_app_and_restarts_from_saved_settings(tmp_path, monkeypatch):
    from bookpocket_companion import cli
    import sys
    servers, apps = [], []
    class FixtureServer:
        def __init__(self, config):
            self.config = config
            self.should_exit = False
            servers.append(self)
        def run(self): pass  # Configuration boundary only: no listener or model launch.
    class FixtureGuard:
        def __init__(self, root): pass
        def close(self): pass
    def create(config):
        app = object()
        apps.append((app, config))
        return app
    monkeypatch.setattr(cli, "create_app", create)
    monkeypatch.setattr(cli, "InstanceGuard", FixtureGuard)
    monkeypatch.setattr(cli, "certificate", lambda config: (tmp_path / "unused.pem", tmp_path / "unused.key"))
    monkeypatch.setattr(cli.uvicorn, "Server", FixtureServer)
    base = ["bookpocket", "serve", "--data-dir", str(tmp_path), "--no-browser"]
    monkeypatch.setattr(sys, "argv", base + ["--phone-gateway-port", "8785", "--public-tls-mode", "system", "--public-url", "https://public.example/bookpocket"])
    cli.main()
    monkeypatch.setattr(sys, "argv", base)
    cli.main()
    assert len(apps) == 2 and len(servers) == 6
    for index in range(2):
        main, studio, phone = servers[index * 3:index * 3 + 3]
        app, config = apps[index]
        assert main.config.app is studio.config.app is phone.config.app.app is app
        assert config.public_tls_mode == "system" and config.phone_gateway_port == 8785
        assert phone.config.host == "127.0.0.1" and phone.config.port == 8785
        assert phone.config.lifespan == "off" and studio.config.lifespan == "off"
        assert phone.config.workers == 1 and phone.config.proxy_headers is False
        assert main.config.lifespan != "off"
        assert phone.should_exit and studio.should_exit
