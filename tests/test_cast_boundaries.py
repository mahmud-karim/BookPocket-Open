"""Casting privacy and exact-source behavior, with no external model requests."""
import json
from pathlib import Path
import uuid
import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion import casting

class ToneCastEngine:
    id, version = "cast-test", "1"
    def __init__(self): self.calls = []
    def info(self): return {"id": self.id, "name": "Test tone", "available": True, "supports_cloning": False, "languages": ["en"], "license": "test", "reason": None}
    def voices(self): return [{"id": f"cast-test:{v}", "name": v, "engine": self.id, "kind": "preset", "language": "en", "created_at": "2026-01-01T00:00:00Z"} for v in ["narrator", "mira", "rowan"]]
    def synthesize(self, text, voice, output, language):
        self.calls.append((text, voice["id"]))
        output.write_bytes((Path(__file__).parent / "fixtures/test-tone.wav").read_bytes())

@pytest.fixture
def cast_api(tmp_path):
    engine = ToneCastEngine()
    app = create_app(Config(data_dir=tmp_path, admin_token="cast-tests-only", dev=True), engines={engine.id: engine}, start_worker=False)
    with TestClient(app, client=("127.0.0.1", 1234), headers={"Authorization": "Bearer cast-tests-only"}) as client:
        book = client.post("/v1/books", files={"file": ("cast.txt", "Mira 🧭 said hello. Rowan replied.\n\nThe lantern glowed.")}).json()
        yield app, client, engine, book


def test_hosted_analysis_requires_explicit_consent_before_outbound_request(cast_api, monkeypatch):
    _, client, _, book = cast_api
    # Narrator-only chapters need no model and must not require hosted consent.
    # Use actual dialogue to exercise the outbound privacy boundary.
    book = client.post("/v1/books", files={"file": ("dialogue.txt", '\u201cThe lantern is ready,\u201d said Mira.')}).json()
    assert client.put("/v1/admin/analyzer", json={"url": "https://model.example.invalid/v1", "model": "test-model", "api_key": "test-placeholder"}).status_code == 200
    def forbid(*args, **kwargs): raise AssertionError("Unauthorized book transmission")
    monkeypatch.setattr(casting.httpx, "Client", forbid)
    assert client.post(f'/v1/books/{book["id"]}/analyze', json={}).status_code == 409
    settings = client.get("/v1/admin/analyzer").json()
    assert settings["hosted"] is True
    assert "api_key" not in settings
    assert "test-placeholder" not in json.dumps(settings)


def test_cast_ranges_reject_unknown_overlapping_and_out_of_bounds(cast_api):
    _, client, _, book = cast_api
    segment = book["chapters"][0]["segments"][0]
    base = {"segment_id": segment["id"], "start_offset": 5, "end_offset": 6, "character_id": "mira", "confidence": .4, "reviewed": False}
    cast = {"characters": [{"id": "mira", "name": "Mira", "aliases": ["Guide"]}], "assignments": [base]}
    assert client.put(f'/v1/books/{book["id"]}/cast', json=cast).status_code == 200
    saved = client.get(f'/v1/books/{book["id"]}/cast').json()
    assert segment["text"][saved["assignments"][0]["start_offset"]:saved["assignments"][0]["end_offset"]] == "🧭"
    for bad in [{**base, "end_offset": 999}, {**base, "segment_id": "missing"}, {**base, "character_id": "missing"}]:
        assert client.put(f'/v1/books/{book["id"]}/cast', json={**cast, "assignments": [bad]}).status_code == 400
    assert client.put(f'/v1/books/{book["id"]}/cast', json={**cast, "assignments": [base, base]}).status_code == 400


def test_changing_one_cast_span_reuses_other_segments(cast_api):
    app, client, engine, book = cast_api
    segments = book["chapters"][0]["segments"]
    base = {"book_id": book["id"], "segment_ids": [s["id"] for s in segments], "engine": engine.id, "voice_id": "cast-test:narrator", "narration_plan": [{"segment_id": segments[0]["id"], "start_offset": 0, "end_offset": 18, "voice_id": "cast-test:mira"}]}
    def render(payload):
        response = client.post("/v1/jobs", json={**payload, "request_id": str(uuid.uuid4())})
        assert response.status_code == 202, response.text
        job = response.json()
        app.state.worker.run(job["id"])
        result = client.get("/v1/jobs/" + job["id"]).json()
        assert result["status"] == "completed", result.get("error")
        return result
    first = render(base)
    calls_before = len(engine.calls)
    second = render({**base, "narration_plan": [{**base["narration_plan"][0], "voice_id": "cast-test:rowan"}]})
    assert first["assets"][1]["id"] == second["assets"][1]["id"]
    assert first["assets"][0]["id"] != second["assets"][0]["id"]
    assert engine.calls[calls_before][1] == "cast-test:rowan"
    assert len(engine.calls) - calls_before == 2
    assert client.get(f'/v1/books/{book["id"]}').json()["chapters"] == book["chapters"]
    timings = second["assets"][0]["timings"]
    assert segments[0]["text"][timings[0]["start_offset"]:timings[0]["end_offset"]] == "Mira 🧭 said hello."
