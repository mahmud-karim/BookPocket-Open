"""Exact ranged casting through the public API and real worker.

Distinct PCM sample values identify only the explicit test engine's routing and
joined output. They do not represent real voices or establish speech quality.
"""
import copy
import hashlib
import io
import json
import struct
import uuid
import wave
import zipfile

import pytest
from fastapi.testclient import TestClient

from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion.store import canonical


SOURCE = "Hidden 🧭. Lead café Mira speaks softly and leaves. Outside.\n\nHidden. 🐦 Rowan waits calmly. Tail."
SELECTED = ["Lead café Mira speaks softly and leaves.", "🐦 Rowan waits calmly."]


class RoutingEngine:
    id, version = "ranged-cast-test", "1"
    samples = {"narrator": 1000, "mira": 2000, "rowan": 3000}

    def __init__(self):
        self.calls = []
        self.fail_on = None

    def info(self):
        return {"id": self.id, "name": "Explicit PCM routing fixture", "available": True,
                "supports_cloning": False, "languages": ["en"], "license": "test"}

    def voices(self):
        return [{"id": self.id + ":" + name, "name": name, "engine": self.id,
                 "kind": "preset", "language": "en"} for name in self.samples]

    def synthesize(self, text, voice, output, language):
        name = voice["id"].split(":")[-1]
        self.calls.append((text, name))
        if self.fail_on == len(self.calls):
            raise RuntimeError("Explicit fixture interruption")
        with wave.open(str(output), "wb") as audio:
            audio.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
            audio.writeframes(struct.pack("<h", self.samples[name]) * 2400)


def connect(directory, engine):
    config = Config(data_dir=directory, admin_token="ranged-cast-tests-only", dev=True)
    app = create_app(config, engines={engine.id: engine}, start_worker=False)
    return app, TestClient(app, client=("127.0.0.1", 7777),
                           headers={"Authorization": "Bearer ranged-cast-tests-only"})


@pytest.fixture
def ranged(tmp_path):
    engine = RoutingEngine()
    app, client = connect(tmp_path / "source", engine)
    with client:
        response = client.post("/v1/books", files={"file": ("original.txt", SOURCE.encode())})
        assert response.status_code == 200, response.text
        book = response.json()
        segments = book["chapters"][0]["segments"]
        ranges, plan = [], []
        for segment, selection, dialogue, voice in zip(segments, SELECTED, ["Mira speaks", "Rowan waits"], ["mira", "rowan"]):
            start = segment["text"].index(selection)
            ranges.append({"segment_id": segment["id"], "start_offset": start, "end_offset": start + len(selection)})
            start = segment["text"].index(dialogue)
            plan.append({"segment_id": segment["id"], "start_offset": start, "end_offset": start + len(dialogue), "voice_id": engine.id + ":" + voice})
        request = {"request_id": str(uuid.uuid4()), "book_id": book["id"], "segment_ids": [s["id"] for s in segments],
                   "engine": engine.id, "voice_id": engine.id + ":narrator", "source_ranges": ranges,
                   "narration_mode": "full_cast", "narration_plan": plan}
        yield app, client, engine, book, request


def render(app, client, request):
    response = client.post("/v1/jobs", json=request)
    assert response.status_code == 202, response.text
    identity = response.json()["id"]
    app.state.worker.run(identity)
    return client.get("/v1/jobs/" + identity).json()


def export_zip(client, job):
    response = client.post(f'/v1/jobs/{job["id"]}/export', json={"format": "project"})
    assert response.status_code == 200, response.text
    return client.get(response.json()["url"]).content


def rewrite_zip(content, edit):
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        entries = {name: archive.read(name) for name in archive.namelist()}
    manifest = json.loads(entries["project.json"])
    edit(manifest)
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w") as archive:
        for name, value in entries.items():
            archive.writestr(name, canonical(manifest) if name == "project.json" else value)
    return result.getvalue()


def test_ranged_cast_routes_exact_original_scalars_and_joins_correct_pcm(ranged):
    app, client, engine, book, request = ranged
    assert "source_ranges_cast" in client.get("/v1/health").json()["capabilities"]
    job = render(app, client, request)
    assert job["status"] == "completed", job.get("error")
    expected = [[("Lead café ", "narrator"), ("Mira speaks", "mira"), ("softly and leaves.", "narrator")],
                [("🐦 ", "narrator"), ("Rowan waits", "rowan"), ("calmly.", "narrator")]]
    assert engine.calls == [call for paragraph in expected for call in paragraph]
    assert job["narration_mode"] == "full_cast"
    assert job["source_ranges"] == request["source_ranges"]
    for asset, segment, scope, calls, plan in zip(job["assets"], book["chapters"][0]["segments"], request["source_ranges"], expected, request["narration_plan"]):
        assert asset["narration_mode"] == "full_cast" and asset["cast_spans"] == [plan]
        assert (asset["source_start"], asset["source_end"]) == (scope["start_offset"], scope["end_offset"])
        content = client.get(asset["url"]).content
        assert hashlib.sha256(content).hexdigest() == asset["sha256"]
        with wave.open(io.BytesIO(content)) as audio:
            assert audio.getnframes() == 7200 and audio.getframerate() == 24000
            assert audio.readframes(7200) == b"".join(struct.pack("<h", engine.samples[voice]) * 2400 for _, voice in calls)
        assert asset["duration"] == pytest.approx(.3)
        assert len(asset["timings"]) == 3
        for index, (timing, (text, _)) in enumerate(zip(asset["timings"], calls)):
            assert segment["text"][timing["start_offset"]:timing["end_offset"]] == text
            assert scope["start_offset"] <= timing["start_offset"] < timing["end_offset"] <= scope["end_offset"]
            assert timing["start"] == pytest.approx(index * .1)
            assert timing["end"] == pytest.approx((index + 1) * .1)
    assert client.get(f'/v1/books/{book["id"]}/source').content == SOURCE.encode()


@pytest.mark.parametrize("fault", ["before-range", "after-range", "other-segment", "overlap", "explicit-single"])
def test_cast_must_stay_inside_selected_page_and_truthful_mode(ranged, fault):
    _, client, engine, _, request = ranged
    if fault == "before-range": request["narration_plan"][0]["start_offset"] = 0
    elif fault == "after-range": request["narration_plan"][0]["end_offset"] = request["source_ranges"][0]["end_offset"] + 1
    elif fault == "other-segment": request["narration_plan"][0]["segment_id"] = "foreign"
    elif fault == "overlap": request["narration_plan"].append(dict(request["narration_plan"][0]))
    else: request["narration_mode"] = "single"
    response = client.post("/v1/jobs", json=request)
    assert response.status_code in (400, 422), response.text
    assert client.get("/v1/jobs").json()["jobs"] == [] and engine.calls == []


def test_narrator_only_full_cast_has_distinct_identity_and_selective_reuse(ranged):
    app, client, engine, _, request = ranged
    request["narration_plan"] = []
    first = render(app, client, request)
    assert first["status"] == "completed", first.get("error")
    assert all(a["narration_mode"] == "full_cast" and a["cast_spans"] == [] for a in first["assets"])
    single = {**request, "narration_mode": "single"}
    assert client.post("/v1/jobs", json=single).status_code == 409
    second = render(app, client, {**single, "request_id": str(uuid.uuid4())})
    assert second["status"] == "completed", second.get("error")
    assert set(a["id"] for a in first["assets"]).isdisjoint(a["id"] for a in second["assets"])
    before = len(engine.calls)
    repeated = render(app, client, {**request, "request_id": str(uuid.uuid4())})
    assert [a["id"] for a in repeated["assets"]] == [a["id"] for a in first["assets"]]
    assert len(engine.calls) == before


def test_changing_one_ranged_character_reuses_other_selected_paragraph(ranged):
    app, client, engine, _, request = ranged
    first = render(app, client, request)
    changed = copy.deepcopy(request)
    changed["request_id"] = str(uuid.uuid4())
    changed["narration_plan"][0]["voice_id"] = engine.id + ":rowan"
    second = render(app, client, changed)
    assert second["status"] == "completed", second.get("error")
    assert first["assets"][0]["id"] != second["assets"][0]["id"]
    assert first["assets"][1]["id"] == second["assets"][1]["id"]
    assert engine.calls[6:] == [("Lead café ", "narrator"), ("Mira speaks", "rowan"), ("softly and leaves.", "narrator")]


def test_narrator_only_paragraph_in_mixed_cast_cannot_relabel_single_asset(ranged):
    app, client, _, _, request = ranged
    single = render(app, client, {**request, "narration_mode": "single", "narration_plan": []})
    mixed_request = {**request, "request_id": str(uuid.uuid4()), "narration_plan": request["narration_plan"][:1]}
    mixed = render(app, client, mixed_request)
    assert mixed["status"] == "completed", mixed.get("error")
    assert mixed["assets"][1]["cast_spans"] == []
    assert mixed["assets"][1]["narration_mode"] == "full_cast"
    assert mixed["assets"][1]["id"] != single["assets"][1]["id"]
    original = client.get(f'/v1/jobs/{single["id"]}').json()
    assert original["assets"][1]["narration_mode"] == "single"


def test_ranged_fullcast_retry_reconstruction_retains_first_completed_asset(ranged, tmp_path):
    app, client, engine, _, request = ranged
    engine.fail_on = 4
    failed = render(app, client, request)
    assert failed["status"] == "failed" and failed["completed_segments"] == 1
    fresh_engine = RoutingEngine()
    restored, other = connect(tmp_path / "source", fresh_engine)
    with other:
        assert other.post(f'/v1/jobs/{failed["id"]}/retry').status_code == 200
        restored.state.worker.run(failed["id"])
        job = other.get(f'/v1/jobs/{failed["id"]}').json()
        assert job["status"] == "completed", job.get("error")
        assert job["narration_mode"] == "full_cast" and job["source_ranges"] == request["source_ranges"]
        assert job["assets"][0]["id"] == failed["assets"][0]["id"]
        assert fresh_engine.calls == [("🐦 ", "narrator"), ("Rowan waits", "rowan"), ("calmly.", "narrator")]


@pytest.mark.parametrize("legacy", [False, True])
def test_portable_fullcast_and_legacy_mode_inference_roundtrip(ranged, tmp_path, legacy):
    app, client, engine, _, request = ranged
    if legacy:
        request.pop("source_ranges")  # Old productions were whole-segment cast.
        request.pop("narration_mode")
    job = render(app, client, request)
    assert job["status"] == "completed", job.get("error")
    content = export_zip(client, job)
    if legacy:
        def strip_mode(manifest):
            manifest["generation"].pop("narration_mode", None)
            manifest["job"].pop("narration_mode", None)
            for asset in manifest["job"]["assets"]: asset.pop("narration_mode", None)
        content = rewrite_zip(content, strip_mode)
        row = app.state.store.item("jobs", job["id"])
        old_request, old_job = json.loads(row["request"]), json.loads(row["data"])
        old_request.pop("narration_mode", None)
        old_job.pop("narration_mode", None)
        for asset in old_job["assets"]: asset.pop("narration_mode", None)
        with app.state.store.db() as db:
            db.execute("UPDATE jobs SET request=?,data=? WHERE id=?", (canonical(old_request), canonical(old_job), job["id"]))
            for asset in old_job["assets"]:
                stored_asset = json.loads(app.state.store.item("assets", asset["id"])["data"])
                stored_asset.pop("narration_mode", None)
                db.execute("UPDATE assets SET data=? WHERE id=?", (canonical(stored_asset), asset["id"]))
        retry = client.post("/v1/jobs", json=request)
        assert retry.status_code == 202 and retry.json()["id"] == job["id"]
        assert retry.json()["narration_mode"] == "full_cast"
        calls_before = len(engine.calls)
        cached = render(app, client, {**request, "request_id": str(uuid.uuid4()), "narration_mode": "full_cast"})
        assert cached["status"] == "completed", cached.get("error")
        assert [asset["id"] for asset in cached["assets"]] == [asset["id"] for asset in job["assets"]]
        assert len(engine.calls) == calls_before
    _, other = connect(tmp_path / "destination", RoutingEngine())
    with other:
        response = other.post("/v1/projects/import", files={"file": ("cast.zip", content)})
        assert response.status_code == 200, response.text
        imported = response.json()["job"]
        assert imported["narration_mode"] == "full_cast"
        assert imported.get("source_ranges", []) == request.get("source_ranges", [])
        for previous, current in zip(job["assets"], imported["assets"]):
            assert current["narration_mode"] == "full_cast"
            for field in ("sha256", "timings", "cast_spans", "source_start", "source_end"):
                assert current[field] == previous[field]
            assert other.get(current["url"]).content == client.get(previous["url"]).content
        assert other.post("/v1/projects/import", files={"file": ("cast.zip", content)}).json()["job"]["id"] == imported["id"]


@pytest.mark.parametrize("fault", ["plan-outside", "asset-plan-outside", "job-mode", "asset-mode"])
def test_portable_cast_rejects_scope_or_mode_laundering(ranged, tmp_path, fault):
    app, client, _, _, request = ranged
    job = render(app, client, request)
    assert job["status"] == "completed", job.get("error")
    def corrupt(manifest):
        if fault == "plan-outside": manifest["generation"]["narration_plan"][0]["start_offset"] = 0
        elif fault == "asset-plan-outside": manifest["job"]["assets"][0]["cast_spans"][0]["start_offset"] = 0
        elif fault == "job-mode": manifest["job"]["narration_mode"] = "single"
        else: manifest["job"]["assets"][0]["narration_mode"] = "single"
    content = rewrite_zip(export_zip(client, job), corrupt)
    directory = tmp_path / "rejected"
    _, other = connect(directory, RoutingEngine())
    with other:
        response = other.post("/v1/projects/import", files={"file": ("invalid.zip", content)})
        assert response.status_code == 400, response.text
        assert other.get("/v1/jobs").json()["jobs"] == []
        assert other.get("/v1/books").json()["books"] == []
        assert list((directory / "assets").glob("*.wav")) == []
