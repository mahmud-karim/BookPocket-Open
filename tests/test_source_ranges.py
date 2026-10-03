"""Selected-source boundaries through the real worker using explicit test-only audio.

The engine records exact synthesis input and emits the public tone fixture. These
checks prove source selection/persistence, never TTS quality or voice identity.
"""
import copy
import hashlib
import io
import json
from pathlib import Path
import shutil
import uuid
import zipfile

import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion.store import canonical

FIXTURES = Path(__file__).parent / "fixtures"
SOURCE = "Before the page. A compass 🧭 points toward café. After the page.\n\nOutside this page. Mira carries the lantern. Beyond this page."


class SelectionEngine:
    id, version = "selection-test", "1"

    def __init__(self):
        self.calls = []
        self.fail_on = None
        self.word_mode = False

    def info(self):
        return {"id": self.id, "name": "Test-only source probe", "available": True,
                "supports_cloning": False, "languages": ["en"], "license": "test", "reason": None}

    def voices(self):
        return [{"id": "selection-test:voice", "name": "Test tone", "engine": self.id,
                 "kind": "preset", "language": "en", "created_at": "2026-01-01T00:00:00Z"}]

    def synthesize(self, text, voice, output, language):
        self.calls.append(text)
        if self.fail_on == len(self.calls):
            raise RuntimeError("Explicit test interruption")
        output.write_bytes((FIXTURES / "test-tone.wav").read_bytes())
        if self.word_mode:
            # One controlled token from the selected original text; no real alignment claim.
            return {"words": [{"text": "cafe", "start": 0.05, "end": 0.20}]}


def connection(config, engine):
    app = create_app(config, engines={engine.id: engine}, start_worker=False)
    client = TestClient(app, client=("127.0.0.1", 4321),
                        headers={"Authorization": "Bearer selection-tests-only"})
    return app, client


@pytest.fixture
def selected(tmp_path):
    if not shutil.which("ffmpeg"):
        pytest.fail("FFmpeg is required to verify selected-source audio normalization")
    engine = SelectionEngine()
    config = Config(data_dir=tmp_path / "source", admin_token="selection-tests-only", dev=True)
    app, client = connection(config, engine)
    with client:
        response = client.post("/v1/books", files={"file": ("selection.txt", SOURCE.encode())})
        assert response.status_code == 200, response.text
        book = response.json()
        segments = book["chapters"][0]["segments"]
        selections = ["A compass 🧭 points toward café.", "Mira carries the lantern."]
        ranges = [{"segment_id": segment["id"], "start_offset": segment["text"].index(text),
                   "end_offset": segment["text"].index(text) + len(text)}
                  for segment, text in zip(segments, selections)]
        request = {"request_id": str(uuid.uuid4()), "book_id": book["id"],
                   "segment_ids": [s["id"] for s in segments], "source_ranges": ranges,
                   "engine": engine.id, "voice_id": "selection-test:voice"}
        yield app, client, engine, config, book, request, selections


def render(app, client, request):
    response = client.post("/v1/jobs", json=request)
    assert response.status_code == 202, response.text
    app.state.worker.run(response.json()["id"])
    return client.get("/v1/jobs/" + response.json()["id"]).json()


def test_capability_and_shared_partial_wire_fixture(selected):
    _, client, _, _, _, _, _ = selected
    health = client.get("/v1/health", headers={"Authorization": ""})
    assert health.status_code == 200
    assert "source_ranges" in health.json()["capabilities"]
    fixture = json.loads((FIXTURES / "contract-v1.json").read_text(encoding="utf-8"))
    segment = fixture["book"]["chapters"][0]["segments"][0]
    span = fixture["partial_request"]["source_ranges"][0]
    asset = fixture["partial_asset"]
    assert span["segment_id"] == asset["segment_id"] == segment["id"]
    assert (span["start_offset"], span["end_offset"]) == (asset["source_start"], asset["source_end"])
    assert segment["text"][asset["source_start"]:asset["source_end"]] == fixture["partial_expected_text"]
    assert fixture["partial_expected_text"].startswith("🧭")


@pytest.mark.parametrize("fault", ["missing", "duplicate", "unknown", "unselected", "past-end", "empty", "reverse", "negative", "float", "boolean", "string"])
def test_range_validation_rejects_ambiguous_or_invalid_selection(selected, fault):
    _, client, engine, _, book, original, _ = selected
    request = copy.deepcopy(original)
    span = request["source_ranges"][0]
    if fault == "missing": request["source_ranges"].pop()
    elif fault == "duplicate": request["source_ranges"].append(dict(span))
    elif fault == "unknown": span["segment_id"] = "absent-segment"
    elif fault == "unselected": request["segment_ids"].pop()
    elif fault == "past-end": span["end_offset"] = len(book["chapters"][0]["segments"][0]["text"]) + 1
    elif fault == "empty": span["end_offset"] = span["start_offset"]
    elif fault == "reverse": span["end_offset"] = span["start_offset"] - 1
    elif fault == "negative": span["start_offset"] = -1
    elif fault == "float": span["start_offset"] = 1.5
    elif fault == "boolean": span["start_offset"] = True
    elif fault == "string": span["start_offset"] = "1"
    response = client.post("/v1/jobs", json=request)
    assert response.status_code in (400, 422), response.text
    assert response.json()["detail"]
    assert client.get("/v1/jobs").json()["jobs"] == []
    assert engine.calls == []


@pytest.mark.parametrize("combination", ["cast", "narration_plan", "announce_chapters"])
def test_partial_selection_rejects_incompatible_narration_options(selected, combination):
    _, client, _, _, _, request, _ = selected
    if combination == "cast": request["cast"] = {request["segment_ids"][0]: request["voice_id"]}
    elif combination == "narration_plan":
        request["narration_plan"] = [{**request["source_ranges"][0], "voice_id": request["voice_id"]}]
    else: request["announce_chapters"] = True
    response = client.post("/v1/jobs", json=request)
    assert response.status_code == 422, response.text
    assert client.get("/v1/jobs").json()["jobs"] == []


def test_worker_speaks_only_selection_with_absolute_unicode_offsets(selected):
    app, client, engine, _, book, request, selections = selected
    result = render(app, client, request)
    assert result["status"] == "completed", result.get("error")
    assert engine.calls == selections
    assert result["source_ranges"] == request["source_ranges"]
    for asset, span, text in zip(result["assets"], request["source_ranges"], selections):
        assert (asset["source_start"], asset["source_end"]) == (span["start_offset"], span["end_offset"])
        assert asset["timings"] == [{"start": 0.0, "end": .25, "start_offset": span["start_offset"], "end_offset": span["end_offset"]}]
        assert hashlib.sha256(client.get(asset["url"]).content).hexdigest() == asset["sha256"]
    assert client.get(f'/v1/books/{book["id"]}/source').content == SOURCE.encode()


def test_partial_word_alignment_maps_pronunciation_back_to_absolute_source(selected):
    app, client, engine, _, book, request, _ = selected
    request["segment_ids"] = request["segment_ids"][:1]
    request["source_ranges"] = request["source_ranges"][:1]
    request["pronunciation_rules"] = [{"term": "café", "replacement": "cafe", "enabled": True}]
    engine.word_mode = True
    result = render(app, client, request)
    assert result["status"] == "completed", result.get("error")
    asset = result["assets"][0]
    expected = book["chapters"][0]["segments"][0]["text"].index("café")
    assert asset["alignment"] == "word"
    assert asset["timings"] == [{"start": .05, "end": .20, "start_offset": expected, "end_offset": expected + 4}]
    assert engine.calls == ["A compass 🧭 points toward cafe."]


def test_distinct_page_slices_have_distinct_cache_and_request_identity(selected):
    app, client, engine, _, _, request, _ = selected
    first = render(app, client, request)
    changed = copy.deepcopy(request)
    changed["source_ranges"][0]["start_offset"] += 2
    assert client.post("/v1/jobs", json=changed).status_code == 409
    changed["request_id"] = str(uuid.uuid4())
    second = render(app, client, changed)
    assert second["status"] == "completed", second.get("error")
    assert first["assets"][0]["id"] != second["assets"][0]["id"]
    assert first["assets"][1]["id"] == second["assets"][1]["id"]
    assert engine.calls[-1] == "compass 🧭 points toward café."
    assert len(engine.calls) == 3
    same = render(app, client, {**changed, "request_id": str(uuid.uuid4())})
    assert [a["id"] for a in same["assets"]] == [a["id"] for a in second["assets"]]
    assert len(engine.calls) == 3


def test_whole_chapter_request_cannot_reuse_partial_page_audio(selected):
    app, client, engine, _, book, request, _ = selected
    partial = render(app, client, request)
    whole_request = {**request, "request_id": str(uuid.uuid4())}
    whole_request.pop("source_ranges")
    whole = render(app, client, whole_request)
    assert whole["status"] == "completed", whole.get("error")
    assert engine.calls[2:] == [
        "Before the page.", "A compass 🧭 points toward café.", "After the page.",
        "Outside this page.", "Mira carries the lantern.", "Beyond this page.",
    ]
    for before, after, segment in zip(partial["assets"], whole["assets"], book["chapters"][0]["segments"]):
        assert before["id"] != after["id"]
        assert after["source_start"] == 0
        assert after["source_end"] == len(segment["text"])
        assert after["duration"] == .75


def test_partial_retry_survives_reconstructed_store_and_preserves_finished_asset(selected):
    app, client, engine, config, _, request, selections = selected
    engine.fail_on = 2
    failed = render(app, client, request)
    assert failed["status"] == "failed"
    assert failed["completed_segments"] == 1
    restarted_engine = SelectionEngine()
    restarted, other = connection(config, restarted_engine)
    with other:
        assert other.post(f'/v1/jobs/{failed["id"]}/retry').status_code == 200
        restarted.state.worker.run(failed["id"])
        finished = other.get(f'/v1/jobs/{failed["id"]}').json()
        assert finished["status"] == "completed", finished.get("error")
        assert finished["completed_segments"] == 2
        assert finished["assets"][0]["id"] == failed["assets"][0]["id"]
        assert restarted_engine.calls == [selections[1]]
        assert finished["source_ranges"] == request["source_ranges"]
        assert len({a["segment_id"] for a in finished["assets"]}) == 2


def test_pre_upgrade_request_without_ranges_remains_idempotent(selected):
    _, client, _, _, _, request, _ = selected
    app = client.app
    request.pop("source_ranges")
    response = client.post("/v1/jobs", json=request)
    assert response.status_code == 202
    job = response.json()
    row = app.state.store.item("jobs", job["id"])
    old_payload = json.loads(row["request"])
    old_payload.pop("source_ranges", None)
    with app.state.store.db() as db:
        db.execute("UPDATE jobs SET request=? WHERE id=?", (canonical(old_payload), job["id"]))
    repeated = client.post("/v1/jobs", json=request)
    assert repeated.status_code == 202, repeated.text
    assert repeated.json()["id"] == job["id"]


def test_partial_project_roundtrip_preserves_ranges_and_absolute_timings(selected, tmp_path):
    app, client, _, _, _, request, _ = selected
    job = render(app, client, request)
    exported = client.post(f'/v1/jobs/{job["id"]}/export', json={"format": "project"})
    assert exported.status_code == 200, exported.text
    content = client.get(exported.json()["url"]).content
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        manifest = json.loads(archive.read("project.json"))
        assert manifest["generation"]["source_ranges"] == request["source_ranges"]
        assert archive.read("source.txt") == SOURCE.encode()
        assert not any(name.startswith("voices/") for name in archive.namelist())
    target, other = connection(Config(data_dir=tmp_path / "destination", admin_token="selection-tests-only", dev=True), SelectionEngine())
    with other:
        imported = other.post("/v1/projects/import", files={"file": ("partial.zip", content)})
        assert imported.status_code == 200, imported.text
        restored = imported.json()["job"]
        assert restored["source_ranges"] == request["source_ranges"]
        assert restored["status"] == "completed"
        for before, after in zip(job["assets"], restored["assets"]):
            for field in ("segment_id", "source_start", "source_end", "timings", "sha256"):
                assert before[field] == after[field]
            assert other.get(after["url"]).content == client.get(before["url"]).content
        assert other.post("/v1/projects/import", files={"file": ("partial.zip", content)}).json()["job"]["id"] == restored["id"]


@pytest.mark.parametrize("corruption", ["missing-key", "not-object", "not-list", "null", "wrong-type", "scope-mismatch", "scope-removed", "timing-before", "timing-after"])
def test_malformed_partial_project_is_rejected_without_persisting_assets(selected, tmp_path, corruption):
    app, client, _, _, _, request, _ = selected
    job = render(app, client, request)
    exported = client.post(f'/v1/jobs/{job["id"]}/export', json={"format": "project"}).json()
    with zipfile.ZipFile(io.BytesIO(client.get(exported["url"]).content)) as archive:
        entries = {name: archive.read(name) for name in archive.namelist()}
    manifest = json.loads(entries["project.json"])
    ranges = manifest["generation"]["source_ranges"]
    if corruption == "missing-key": ranges[0].pop("end_offset")
    elif corruption == "not-object": ranges[0] = "invalid"
    elif corruption == "not-list": manifest["generation"]["source_ranges"] = {"invalid": "shape"}
    elif corruption == "null": manifest["generation"]["source_ranges"] = None
    elif corruption == "wrong-type": ranges[0]["start_offset"] = True
    elif corruption == "scope-mismatch": ranges[0]["start_offset"] += 1
    elif corruption == "scope-removed":
        manifest["generation"].pop("source_ranges")
        manifest["job"].pop("source_ranges")
    elif corruption == "timing-before": manifest["job"]["assets"][0]["timings"][0]["start_offset"] = 0
    elif corruption == "timing-after": manifest["job"]["assets"][0]["timings"][0]["end_offset"] += 1
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, content in entries.items():
            archive.writestr(name, canonical(manifest) if name == "project.json" else content)
    directory = tmp_path / "rejected-import"
    target, other = connection(Config(data_dir=directory, admin_token="selection-tests-only", dev=True), SelectionEngine())
    with other:
        response = other.post("/v1/projects/import", files={"file": ("malformed.zip", output.getvalue())})
        assert response.status_code == 400, response.text
        assert response.json()["detail"]
        assert other.get("/v1/books").json()["books"] == []
        assert other.get("/v1/jobs").json()["jobs"] == []
        assert list((directory / "assets").glob("*.wav")) == []
