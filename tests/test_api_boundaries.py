"""Independent API tests: authentication, revocation, original bytes and job identity."""
import json
from pathlib import Path
import uuid
import shutil
from fastapi.testclient import TestClient
import pytest
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config

FIXTURES = Path(__file__).parent / "fixtures"
ADMIN = {"Authorization": "Bearer integration-admin-not-a-real-token"}

class FixtureEngine:
    """Injected in tests only. No speech or production engine claim."""
    id = "fixture"
    version = "test-only-1"
    def info(self):
        return {"id": self.id, "name": "Test-only tone transport", "available": True, "supports_cloning": False, "languages": ["en"], "license": "Apache-2.0", "reason": None}
    def voices(self):
        return [{"id": "fixture:preset", "name": "Test tone", "engine": self.id, "kind": "preset", "language": "en", "created_at": "2026-01-01T00:00:00Z"}]
    def synthesize(self, text, voice, output, language="en"):
        raise AssertionError("This API fixture does not synthesize speech")

@pytest.fixture
def api(tmp_path):
    app = create_app(Config(data_dir=tmp_path, admin_token=ADMIN["Authorization"][7:], dev=True), engines={"fixture": FixtureEngine()}, start_worker=False)
    with TestClient(app, base_url="http://localhost:8783", client=("127.0.0.1", 1234)) as client:
        yield app, client


def pair(client):
    ticket = client.post("/v1/admin/pairing-tickets", headers=ADMIN).json()
    request = client.post("/v1/pairings", json={"code": ticket["code"], "device_name": "Integration phone"})
    assert request.status_code == 200
    pending = request.json()
    poll_header = {"Authorization": "Bearer " + pending["poll_token"]}
    assert client.get("/v1/pairings/" + pending["id"], headers=poll_header).json() == {"status": "pending"}
    assert client.post("/v1/admin/pairings/" + pending["id"] + "/approve", headers=ADMIN).status_code == 200
    approved = client.get("/v1/pairings/" + pending["id"], headers=poll_header).json()
    assert client.get("/v1/pairings/" + pending["id"], headers=poll_header).json() == approved
    assert client.post("/v1/pairings", json={"code": ticket["code"], "device_name": "Duplicate"}).status_code == 400
    return approved, pending, poll_header


def test_pairing_requires_approval_and_revocation_denies_replay(api):
    app, client = api
    assert client.get("/v1/health").json()["api_version"] == "1"
    assert client.get("/v1/books").status_code == 401
    approved, pending, poll_header = pair(client)
    device_header = {"Authorization": "Bearer " + approved["device_token"]}
    assert client.get("/v1/books", headers=device_header).status_code == 200
    assert client.get("/v1/admin/devices", headers=device_header).status_code == 403
    with app.state.store.db() as db:
        stored = db.execute("SELECT token_hash FROM devices WHERE id=?", (approved["device_id"],)).fetchone()[0]
    assert stored != approved["device_token"]
    assert client.delete("/v1/devices/current", headers=device_header).status_code == 200
    assert client.get("/v1/books", headers=device_header).status_code == 401
    assert client.get("/v1/pairings/" + pending["id"], headers=poll_header).json()["status"] == "rejected"


def test_transport_and_browser_origin_boundaries(api):
    app, client = api
    assert client.post("/v1/admin/pairing-tickets", headers={**ADMIN, "Origin": "https://untrusted.invalid"}).status_code == 403
    assert client.post("/v1/admin/pairing-tickets", headers={**ADMIN, "Origin": "http://localhost:8784"}).status_code == 200
    with TestClient(app, base_url="http://localhost:8783", client=("192.0.2.1", 1234)) as remote:
        assert remote.get("/v1/health", headers={"X-Forwarded-Proto": "https", "X-Forwarded-For": "127.0.0.1"}).status_code == 403
    with TestClient(app, base_url="https://localhost:8783", client=("192.0.2.1", 1234)) as remote:
        assert remote.get("/v1/health").status_code == 200
        assert remote.post("/v1/admin/pairing-tickets", headers=ADMIN).status_code == 403


def test_import_original_and_idempotent_conflict_and_cancel(api):
    _, client = api
    raw = (FIXTURES / "lantern.epub").read_bytes()
    response = client.post("/v1/books", files={"file": ("lantern.epub", raw, "application/epub+zip")}, headers=ADMIN)
    assert response.status_code == 200, response.text
    book = response.json()
    assert client.get(f'/v1/books/{book["id"]}/source', headers=ADMIN).content == raw
    assert client.get(f'/v1/books/{book["id"]}/source').status_code == 401
    request = {"request_id": str(uuid.uuid4()), "book_id": book["id"], "segment_ids": [book["chapters"][0]["segments"][1]["id"]], "engine": "fixture", "voice_id": "fixture:preset", "language": "en"}
    first = client.post("/v1/jobs", json=request, headers=ADMIN)
    assert first.status_code == 202, first.text
    job = first.json()
    assert client.post("/v1/jobs", json=request, headers=ADMIN).json()["id"] == job["id"]
    assert client.post("/v1/jobs", json={**request, "announce_chapters": True}, headers=ADMIN).status_code == 409
    assert client.delete(f'/v1/books/{book["id"]}', headers=ADMIN).status_code == 409
    assert client.post(f'/v1/jobs/{job["id"]}/cancel', headers=ADMIN).json()["status"] == "cancelled"
    assert client.post(f'/v1/jobs/{job["id"]}/resume', headers=ADMIN).status_code == 409
    assert client.post(f'/v1/jobs/{job["id"]}/retry', headers=ADMIN).json()["status"] == "queued"
    assert client.post(f'/v1/jobs/{job["id"]}/export', json={"format": "project"}, headers=ADMIN).status_code == 409


def test_expired_ticket_and_exchange_and_rate_limit(api):
    app, client = api
    ticket = client.post("/v1/admin/pairing-tickets", headers=ADMIN).json()
    with app.state.store.db() as db:
        db.execute("UPDATE tickets SET expires=0 WHERE id=?", (ticket["id"],))
    assert client.post("/v1/pairings", json={"code": ticket["code"], "device_name": "Late phone"}).status_code == 400
    approved, pending, poll_header = pair(client)
    with app.state.store.db() as db:
        db.execute("UPDATE pairings SET expires=0 WHERE id=?", (pending["id"],))
    assert client.get("/v1/pairings/" + pending["id"], headers=poll_header).json() == {"status": "expired"}
    with app.state.store.db() as db:
        assert db.execute("SELECT encrypted_token FROM pairings WHERE id=?", (pending["id"],)).fetchone()[0] is None
    statuses = [client.post("/v1/pairings", json={"code": "INVALID-CODE", "device_name": "Guess"}).status_code for _ in range(13)]
    assert statuses[-1] == 429


@pytest.mark.parametrize("manifest", ["null", "[]", "42", '{"source_sha256":"mismatch","chapters":[]}'])
def test_malformed_manifest_returns_actionable_client_error(api, manifest):
    _, client = api
    raw = (FIXTURES / "lantern.epub").read_bytes()
    response = client.post("/v1/books", files={"file": ("lantern.epub", raw, "application/epub+zip")}, data={"manifest": manifest}, headers=ADMIN)
    assert response.status_code in {400, 409, 422}
    assert response.json().get("detail")


@pytest.mark.parametrize("status", ["failed", "cancelled"])
def test_phone_deletes_terminal_queue_without_audio_and_cannot_retry_after_restart(api, status):
    app, client = api
    raw = b"Original queue test.\n\nThe book remains available."
    book = client.post("/v1/books", files={"file": ("original.txt", raw)}, headers=ADMIN).json()
    request = {"request_id": str(uuid.uuid4()), "book_id": book["id"],
               "segment_ids": [book["chapters"][0]["segments"][0]["id"]],
               "engine": "fixture", "voice_id": "fixture:preset", "language": "en"}
    job = client.post("/v1/jobs", json=request, headers=ADMIN).json()
    other = client.post("/v1/jobs", json={**request, "request_id": str(uuid.uuid4())}, headers=ADMIN).json()
    if status == "failed":
        app.state.worker.run(job["id"])
    else:
        assert client.post(f'/v1/jobs/{job["id"]}/cancel', headers=ADMIN).status_code == 200
    terminal = client.get(f'/v1/jobs/{job["id"]}', headers=ADMIN).json()
    assert terminal["status"] == status and terminal["assets"] == []
    approved, _, _ = pair(client)
    phone = {"Authorization": "Bearer " + approved["device_token"]}
    assert client.delete(f'/v1/jobs/{job["id"]}').status_code == 401
    assert client.delete(f'/v1/jobs/{job["id"]}', headers=phone).status_code == 204
    restarted = create_app(app.state.config, engines={"fixture": FixtureEngine()}, start_worker=False)
    with TestClient(restarted, base_url="http://localhost:8783", client=("127.0.0.1", 1234)) as fresh:
        assert fresh.delete(f'/v1/jobs/{job["id"]}', headers=phone).status_code == 204
        assert job["id"] not in {j["id"] for j in fresh.get("/v1/jobs", headers=phone).json()["jobs"]}
        assert fresh.post(f'/v1/jobs/{job["id"]}/retry', headers=phone).status_code == 404
        assert fresh.post("/v1/jobs", json=request, headers=phone).status_code == 410
        assert fresh.get(f'/v1/jobs/{other["id"]}', headers=phone).json()["status"] == "queued"
        assert fresh.get(f'/v1/books/{book["id"]}/source', headers=phone).content == raw


def test_deleting_partly_generated_failed_queue_retains_audio_used_by_completed_take(api):
    if not shutil.which("ffmpeg"):
        pytest.skip("FFmpeg validates actual published test-tone audio")
    app, client = api
    class PartialToneEngine(FixtureEngine):
        version = "queue-deletion-test-only"
        def synthesize(self, text, voice, output, language="en"):
            if text.startswith("Second"):
                raise RuntimeError("Explicit test-only second-passage failure")
            output.write_bytes((FIXTURES / "test-tone.wav").read_bytes())
    app.state.worker.engines["fixture"] = PartialToneEngine()
    raw = b"First original passage.\n\nSecond original passage."
    book = client.post("/v1/books", files={"file": ("original.txt", raw)}, headers=ADMIN).json()
    segments = [s["id"] for s in book["chapters"][0]["segments"]]
    request = {"request_id": str(uuid.uuid4()), "book_id": book["id"], "segment_ids": segments,
               "engine": "fixture", "voice_id": "fixture:preset", "language": "en"}
    failed = client.post("/v1/jobs", json=request, headers=ADMIN).json()
    app.state.worker.run(failed["id"])
    failed = client.get(f'/v1/jobs/{failed["id"]}', headers=ADMIN).json()
    assert failed["status"] == "failed" and failed["completed_segments"] == 1
    assert len(failed["assets"]) == 1
    complete = client.post("/v1/jobs", json={**request, "request_id": str(uuid.uuid4()), "segment_ids": segments[:1]}, headers=ADMIN).json()
    app.state.worker.run(complete["id"])
    complete = client.get(f'/v1/jobs/{complete["id"]}', headers=ADMIN).json()
    assert complete["status"] == "completed" and complete["assets"][0]["id"] == failed["assets"][0]["id"]
    asset = complete["assets"][0]
    before = client.get(asset["url"], headers=ADMIN).content
    assert client.delete(f'/v1/jobs/{failed["id"]}', headers=ADMIN).status_code == 204
    assert client.get(asset["url"], headers=ADMIN).content == before
    assert client.get(f'/v1/jobs/{complete["id"]}', headers=ADMIN).json() == complete
    assert client.get(f'/v1/books/{book["id"]}/source', headers=ADMIN).content == raw
