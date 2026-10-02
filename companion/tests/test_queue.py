import json
from pathlib import Path
import shutil
import wave
import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion.worker import sentences, spoken


class TestEngine:
    __test__ = False
    id, version = "fixture", "1"
    def __init__(self): self.calls, self.fail_on, self.hook = [], None, None
    def info(self): return {"id": self.id, "name": "Explicit test fixture", "available": True, "supports_cloning": False, "languages": ["en"], "license": "test", "reason": None}
    def voices(self): return [{"id": "fixture:voice", "name": "Fixture", "engine": self.id, "kind": "preset", "language": "en", "created_at": "2026-01-01T00:00:00Z"}]
    def synthesize(self, text, voice, output, language):
        self.calls.append(text)
        if self.fail_on == len(self.calls): raise RuntimeError("Test engine interrupted")
        with wave.open(str(output), "wb") as wav:
            wav.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\0\0" * 2400)
        if self.hook: self.hook()


@pytest.fixture
def setup(tmp_path):
    if not shutil.which("ffmpeg"): pytest.skip("ffmpeg required for actual audio normalization boundary")
    engine = TestEngine()
    config = Config(data_dir=tmp_path, admin_token="test-secret", dev=True)
    app = create_app(config, engines={engine.id: engine}, start_worker=False)
    client = TestClient(app, client=("127.0.0.1", 2345), headers={"Authorization": "Bearer test-secret"})
    book = client.post("/v1/books", files={"file": ("chapter.txt", "A compass 🧭. A second sentence.\n\nFinal paragraph.")}).json()
    request = {"request_id": "test1", "book_id": book["id"], "segment_ids": [s["id"] for c in book["chapters"] for s in c["segments"]], "engine": "fixture", "voice_id": "fixture:voice", "pronunciation_rules": [{"term": "compass", "replacement": "navigation compass", "enabled": True}]}
    return app, client, engine, config, request


def test_failure_retry_preserves_segments_and_original_offsets(setup):
    app, client, engine, config, request = setup
    engine.fail_on = 3
    job = client.post("/v1/jobs", json=request).json()
    app.state.worker.run(job["id"])
    failed = client.get("/v1/jobs/"+job["id"]).json()
    assert failed["status"] == "failed"
    assert failed["completed_segments"] == 1
    assert failed["assets"][0]["timings"][0]["end_offset"] == len("A compass 🧭.")
    assert engine.calls[0] == "A navigation compass 🧭."
    assert client.post("/v1/jobs", json=request).json()["id"] == job["id"]
    engine.fail_on = None
    # Reconstruct app/store to exercise persistence rather than in-memory retry.
    restarted = create_app(config, engines={engine.id: engine}, start_worker=False)
    client2 = TestClient(restarted, client=("127.0.0.1", 2345), headers={"Authorization": "Bearer test-secret"})
    assert client2.post(f"/v1/jobs/{job['id']}/retry").status_code == 200
    restarted.state.worker.run(job["id"])
    finished = client2.get("/v1/jobs/"+job["id"]).json()
    assert finished["status"] == "completed"
    assert finished["completed_segments"] == 2
    assert len(engine.calls) == 4  # first completed paragraph reused from validated cache
    assert len({a["segment_id"] for a in finished["assets"]}) == 2
    audio = client2.get(finished["assets"][0]["url"], headers={"Range": "bytes=0-43"})
    assert audio.status_code == 206
    assert audio.content[:4] == b"RIFF"
    exported = client2.post(f"/v1/jobs/{job['id']}/export", json={"format": "project"})
    assert exported.status_code == 200, exported.text
    assert client2.get(exported.json()["url"]).content[:2] == b"PK"


def test_cancellation_during_generation_never_publishes(setup):
    app, client, engine, _, request = setup
    job = client.post("/v1/jobs", json=request).json()
    engine.hook = lambda: client.post(f"/v1/jobs/{job['id']}/cancel")
    app.state.worker.run(job["id"])
    result = client.get("/v1/jobs/"+job["id"]).json()
    assert result["status"] == "cancelled"
    assert result["assets"] == []


def test_corrupt_cache_is_regenerated(setup):
    app, client, engine, _, request = setup
    job = client.post("/v1/jobs", json=request).json()
    app.state.worker.run(job["id"])
    completed = client.get("/v1/jobs/"+job["id"]).json()
    asset_row = app.state.store.item("assets", completed["assets"][0]["id"])
    Path(asset_row["path"]).write_bytes(b"broken")
    request["request_id"] = "second"
    retry = client.post("/v1/jobs", json=request).json()
    app.state.worker.run(retry["id"])
    assert client.get("/v1/jobs/"+retry["id"]).json()["status"] == "completed"
    assert len(engine.calls) == 5


def test_sentence_offsets_and_substitution():
    text = "Hello 🧭. Next sentence!"
    assert [(text[a:b], t) for a, b, t in sentences(text)] == [("Hello 🧭.", "Hello 🧭."), ("Next sentence!", "Next sentence!")]
    assert spoken("Anna and Ann", [{"term": "Ann", "replacement": "Anne", "enabled": True}]) == "Anna and Anne"
