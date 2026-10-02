import json
import io
import zipfile
import uuid
from pathlib import Path
import shutil
import wave
import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion.store import canonical, now
from bookpocket_companion.worker import sentences, spoken, spoken_mapping, word_timings


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
    archive = client2.get(exported.json()["url"]).content
    assert archive[:2] == b"PK"
    imported = client2.post("/v1/projects/import", files={"file": ("project.zip", archive)})
    assert imported.status_code == 200, imported.text
    assert imported.json()["book"]["source_sha256"] == request["book_id"]
    assert imported.json()["job"]["completed_segments"] == 2
    again = client2.post("/v1/projects/import", files={"file": ("project.zip", archive)})
    assert again.json()["job"]["id"] == imported.json()["job"]["id"]


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

def test_new_take_bypasses_cache_but_retry_keeps_completed_audio(setup):
    app, client, engine, _, request = setup
    original = client.post("/v1/jobs", json=request).json()
    app.state.worker.run(original["id"])
    original = client.get("/v1/jobs/"+original["id"]).json()
    request.update(request_id="new-take", take_id=str(uuid.uuid4()))
    engine.fail_on = 6
    take = client.post("/v1/jobs", json=request).json()
    app.state.worker.run(take["id"])
    partial = client.get("/v1/jobs/"+take["id"]).json()
    assert partial["status"] == "failed"
    assert partial["assets"][0]["id"] != original["assets"][0]["id"]
    engine.fail_on = None
    client.post(f"/v1/jobs/{take['id']}/retry")
    app.state.worker.run(take["id"])
    final = client.get("/v1/jobs/"+take["id"]).json()
    assert final["status"] == "completed"
    assert final["assets"][0]["id"] == partial["assets"][0]["id"]
    assert len(engine.calls) == 7


def test_sentence_offsets_and_substitution():
    text = "Hello 🧭. Next sentence!"
    assert [(text[a:b], t) for a, b, t in sentences(text)] == [("Hello 🧭.", "Hello 🧭."), ("Next sentence!", "Next sentence!")]
    assert spoken("Anna and Ann", [{"term": "Ann", "replacement": "Anne", "enabled": True}]) == "Anna and Anne"

def test_model_word_mapping_preserves_original_pronunciation_span():
    text, mapping = spoken_mapping("Hi 🧭 Kyon.", [{"term": "Kyon", "replacement": "Key on", "enabled": True}])
    result = {"words": [{"text": "Key", "start": .2, "end": .4}, {"text": "on", "start": .4, "end": .6}]}
    times = word_timings(result, text, mapping, 0, 0, 1)
    assert [(t["start_offset"], t["end_offset"]) for t in times] == [(5, 9), (5, 9)]
    assert word_timings({"words": [{"text": "invented", "start": 0, "end": 1}]}, text, mapping, 0, 0, 1) is None

def test_multiple_speakers_in_one_segment_and_overlap_validation(setup):
    app, client, engine, _, request = setup
    sid = request["segment_ids"][0]
    request["narration_plan"] = [{"segment_id": sid, "start_offset": 2, "end_offset": 9, "voice_id": "fixture:voice"}, {"segment_id": sid, "start_offset": 8, "end_offset": 12, "voice_id": "fixture:voice"}]
    assert client.post("/v1/jobs", json=request).status_code == 400
    request["narration_plan"] = request["narration_plan"][:1]
    job = client.post("/v1/jobs", json=request).json()
    app.state.worker.run(job["id"])
    result = client.get("/v1/jobs/"+job["id"]).json()
    assert result["status"] == "completed"
    assert result["assets"][0]["cast_spans"] == request["narration_plan"]
    assert any(t["start_offset"] == 2 and t["end_offset"] == 9 for t in result["assets"][0]["timings"])

def test_project_cast_and_voice_reference_opt_in(setup, tmp_path):
    app, client, engine, config, request = setup
    reference = config.data_dir / "voices" / "reference.wav"
    with wave.open(str(reference), "wb") as wav:
        wav.setparams((1, 2, 24000, 0, "NONE", "not compressed")); wav.writeframes(b"\0\0" * 24000 * 4)
    voice = {"id": "owned-clone", "name": "Owned reference", "engine": "fixture", "kind": "clone", "language": "en", "created_at": now()}
    with app.state.store.db() as db:
        db.execute("INSERT INTO voices VALUES(?,?,?,?)", (voice["id"], canonical(voice), str(reference), "private reference transcript"))
    request["voice_id"] = voice["id"]
    job = client.post("/v1/jobs", json=request).json()
    app.state.worker.run(job["id"])
    cast = {"characters": [{"id": "narrator", "name": "Narrator", "aliases": ["keeper"], "voice_id": voice["id"]}], "assignments": []}
    assert client.put(f"/v1/books/{request['book_id']}/cast", json=cast).status_code == 200
    for include in (False, True):
        asset = client.post(f"/v1/jobs/{job['id']}/export", json={"format": "project", "include_voice_references": include}).json()
        content = client.get(asset["url"]).content
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            manifest = json.loads(archive.read("project.json"))
            assert manifest["cast"]["characters"][0]["aliases"] == ["keeper"]
            assert bool([n for n in archive.namelist() if n.startswith("voices/")]) is include
            if not include: assert "private reference transcript" not in archive.read("project.json").decode()
        target = create_app(Config(data_dir=tmp_path / ("with-voice" if include else "without-voice"), admin_token="target", dev=True), engines={}, start_worker=False)
        other = TestClient(target, client=("127.0.0.1", 7777), headers={"Authorization": "Bearer target"})
        imported = other.post("/v1/projects/import", files={"file": ("project.zip", content)})
        assert imported.status_code == 200, imported.text
        assert bool(imported.json()["unresolved_voices"]) is not include
        assert len(other.get("/v1/voices").json()["voices"]) == (1 if include else 0)
        assert other.get(f"/v1/books/{request['book_id']}/cast").json()["characters"][0]["aliases"] == ["keeper"]
