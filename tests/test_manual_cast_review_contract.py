"""Real API/worker review boundaries with original public text and explicit PCM.

The routing fixture tests saved speaker choices and exact source spans, not voice
quality. No private books, recordings, analyzer models or credentials are used.
"""
import copy
import uuid

import pytest
from fastapi.testclient import TestClient

from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion.store import canonical
from test_incremental_cast_contract import wait_analysis
from test_ranged_cast import RoutingEngine, render


ORIGINAL = "🧭 Café bells rang. Mira said, “Keep the lantern steady.\n\n🐦 Rowan said, “The north path is clear."


@pytest.fixture
def review_book(tmp_path):
    engine = RoutingEngine()
    config = Config(data_dir=tmp_path, admin_token="manual-review-tests-only", dev=True)
    app = create_app(config, engines={engine.id: engine}, start_worker=False)
    with TestClient(app, client=("127.0.0.1", 7777), headers={"Authorization": "Bearer manual-review-tests-only"}) as client:
        response = client.post("/v1/books", files={"file": ("Original lantern review.txt", ORIGINAL.encode())})
        assert response.status_code == 200, response.text
        book = response.json()
        route = "/v1/books/" + book["id"]
        saved = {"characters": [{"id": "narrator", "name": "Narrator", "aliases": [], "voice_id": engine.id + ":narrator"}], "assignments": []}
        assert client.put(route + "/cast", json=saved).status_code == 200
        assert client.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1/v1", "model": "explicit-unused-review-analyzer"}).status_code == 200
        response = client.post(route + "/analyze", json={"request_id": str(uuid.uuid4()), "chapter_ids": [book["chapters"][0]["id"]]})
        assert response.status_code == 202, response.text
        analysis = wait_analysis(client, response.json()["id"])
        inventory = client.get(route + "/review-issues")
        assert inventory.status_code == 200, inventory.text
        assert len(inventory.json()["issues"]) == 2, inventory.json()
        yield app, client, engine, config, book, route, analysis


def resolve_body(inventory, character="mira", voice="mira", *, new=True):
    body = {"request_id": str(uuid.uuid4()), "expected_revision": inventory["revision"],
            "character_id": character, "voice_id": "ranged-cast-test:" + voice}
    if new:
        body["new_character"] = {"id": character, "name": character.capitalize(), "aliases": ["Lantern keeper"] if character == "mira" else []}
    return body


def selected_request(book, issue, voice="mira"):
    return {"request_id": str(uuid.uuid4()), "book_id": book["id"], "segment_ids": [issue["segment_id"]],
            "engine": "ranged-cast-test", "voice_id": "ranged-cast-test:narrator", "language": "en",
            "narration_mode": "full_cast", "source_ranges": [{k: issue[k] for k in ("segment_id", "start_offset", "end_offset")}],
            "narration_plan": [{**{k: issue[k] for k in ("segment_id", "start_offset", "end_offset")}, "voice_id": "ranged-cast-test:" + voice}]}


def test_manual_review_exact_unicode_unblocks_only_selected_page_and_survives_restart(review_book):
    app, client, engine, config, book, route, _ = review_book
    assert "casting_review" in client.get("/v1/health").json()["capabilities"]
    inventory = client.get(route + "/review-issues").json()
    assert inventory["book_id"] == book["id"] and inventory["source_sha256"] == book["source_sha256"]
    assert inventory == client.get(route + "/review-issues", params={"chapter_id": book["chapters"][0]["id"]}).json()
    assert client.get(route + "/review-issues", params={"chapter_id": "foreign"}).status_code == 400
    first, second = inventory["issues"]
    sources = {s["id"]: s["text"] for c in book["chapters"] for s in c["segments"]}
    for issue in inventory["issues"]:
        assert issue["status"] == "pending"
        assert issue["source_text"] == sources[issue["segment_id"]][issue["start_offset"]:issue["end_offset"]]
    assert "🧭" in first["source_text"] and "Café" in first["source_text"]
    request = selected_request(book, first)
    assert client.post("/v1/jobs", json=request).status_code == 409
    assert client.get("/v1/jobs").json()["jobs"] == [] and engine.calls == []
    # Choosing Single remains explicit and unaffected by unresolved cast issues.
    single = render(app, client, {**request, "request_id": str(uuid.uuid4()), "narration_mode": "single", "narration_plan": []})
    assert single["status"] == "completed"
    body = resolve_body(inventory)
    response = client.post(route + "/review-issues/" + first["id"] + "/resolve", json=body)
    assert response.status_code == 200, response.text
    result = response.json()
    assert result["issue"]["status"] == "resolved" and result["revision"] > inventory["revision"]
    assignment = next(a for a in result["cast"]["assignments"] if a["segment_id"] == first["segment_id"])
    assert assignment["reviewed"] and assignment["character_id"] == "mira"
    assert (assignment["start_offset"], assignment["end_offset"]) == (first["start_offset"], first["end_offset"])
    assert next(c for c in result["cast"]["characters"] if c["id"] == "mira")["voice_id"] == engine.id + ":mira"
    remaining = client.get(route + "/review-issues").json()["issues"]
    assert next(i for i in remaining if i["id"] == second["id"])["status"] == "pending"
    # A pending later passage must not block this already reviewed selected page.
    before = len(engine.calls)
    job = render(app, client, {**request, "request_id": str(uuid.uuid4())})
    assert job["status"] == "completed", job.get("error")
    calls = engine.calls[before:]
    assert calls and all(voice == "mira" for _, voice in calls)
    assert " ".join(text for text, _ in calls) == first["source_text"]
    assert client.post("/v1/jobs", json=selected_request(book, second, "rowan")).status_code == 409
    assert client.get(route + "/source").content == ORIGINAL.encode()
    restored = create_app(config, engines={engine.id: engine}, start_worker=False)
    with TestClient(restored, client=("127.0.0.1", 7777), headers={"Authorization": "Bearer manual-review-tests-only"}) as other:
        assert other.get(route + "/cast").json() == result["cast"]
        assert other.get(route + "/review-issues").json()["issues"] == remaining


@pytest.mark.parametrize("fault", ["gap", "overlap", "wrong-source-bound", "unknown-voice", "unknown-character"])
def test_manual_review_rejects_incomplete_or_unknown_choices_without_mutation(review_book, fault):
    _, client, _, _, _, route, _ = review_book
    inventory = client.get(route + "/review-issues").json()
    issue = inventory["issues"][0]
    body = resolve_body(inventory)
    if fault == "unknown-voice": body["voice_id"] = "missing-private-voice"
    elif fault == "unknown-character": body.pop("new_character")
    else:
        low, high = issue["start_offset"], issue["end_offset"]
        middle = (low + high) // 2
        spans = [{"start_offset": low, "end_offset": middle, "character_id": "mira"},
                 {"start_offset": middle, "end_offset": high, "character_id": "narrator"}]
        if fault == "gap": spans[1]["start_offset"] += 1
        elif fault == "overlap": spans[1]["start_offset"] -= 1
        else: spans[1]["end_offset"] += 1
        body["ranges"] = spans
    before = client.get(route + "/cast").json()
    response = client.post(route + "/review-issues/" + issue["id"] + "/resolve", json=body)
    assert response.status_code in {400, 404, 409, 422}, response.text
    assert client.get(route + "/cast").json() == before
    assert client.get(route + "/review-issues").json() == inventory
    assert client.get("/v1/jobs").json()["jobs"] == []


def test_manual_review_conflict_and_old_retry_cannot_overwrite_later_user_edit(review_book):
    _, client, _, _, _, route, _ = review_book
    inventory = client.get(route + "/review-issues").json()
    issue = inventory["issues"][0]
    stale_body = resolve_body(inventory)
    saved = client.get(route + "/cast").json()
    saved["characters"][0]["aliases"] = ["Desktop-authoritative alias"]
    assert client.put(route + "/cast", json=saved).status_code == 200
    assert client.post(route + "/review-issues/" + issue["id"] + "/resolve", json=stale_body).status_code == 409
    assert client.get(route + "/cast").json() == saved
    current = client.get(route + "/review-issues").json()
    body = resolve_body(current)
    first = client.post(route + "/review-issues/" + issue["id"] + "/resolve", json=body)
    assert first.status_code == 200, first.text
    changed = copy.deepcopy(first.json()["cast"])
    changed["assignments"] = []
    changed["characters"][1]["name"] = "Phone correction after save"
    assert client.put(route + "/cast", json=changed).status_code == 200
    retry = client.post(route + "/review-issues/" + issue["id"] + "/resolve", json=body)
    assert retry.status_code == 200, retry.text
    assert retry.json()["cast"] == changed and retry.json()["issue"]["status"] == "pending"
    assert client.get(route + "/cast").json() == changed
    conflict = {**body, "voice_id": "ranged-cast-test:rowan"}
    assert client.post(route + "/review-issues/" + issue["id"] + "/resolve", json=conflict).status_code == 409
    assert client.get(route + "/cast").json() == changed


@pytest.mark.parametrize("fault", ["missing-narrator", "missing-other-speaker", "wrong-engine", "deleted-clone"])
def test_manual_review_requires_current_compatible_voices_for_every_explicit_speaker(review_book, fault):
    app, client, engine, _, _, route, _ = review_book
    cast = client.get(route + "/cast").json()
    if fault == "missing-narrator":
        cast["characters"][0]["voice_id"] = None
    elif fault == "missing-other-speaker":
        cast["characters"].append({"id": "rowan", "name": "Rowan", "aliases": [], "voice_id": None})
    if fault in {"missing-narrator", "missing-other-speaker"}:
        assert client.put(route + "/cast", json=cast).status_code == 200
    inventory = client.get(route + "/review-issues").json()
    issue = inventory["issues"][0]
    body = resolve_body(inventory)
    if fault == "missing-other-speaker":
        middle = (issue["start_offset"] + issue["end_offset"]) // 2
        body["ranges"] = [{"start_offset": issue["start_offset"], "end_offset": middle, "character_id": "mira"},
                          {"start_offset": middle, "end_offset": issue["end_offset"], "character_id": "rowan"}]
    elif fault == "wrong-engine":
        other = RoutingEngine(); other.id = "other-explicit-routing-test"
        app.state.worker.engines[other.id] = other
        body["voice_id"] = other.id + ":mira"
    elif fault == "deleted-clone":
        identity = str(uuid.uuid4())
        reference = app.state.store.root / "voices" / (identity + ".wav")
        reference.parent.mkdir(exist_ok=True); reference.write_bytes(b"explicit unused test reference")
        voice = {"id": identity, "name": "Explicit deleted review reference", "engine": engine.id, "kind": "clone", "language": "en"}
        with app.state.store.db() as db:
            db.execute("INSERT INTO voices VALUES(?,?,?,?)", (identity, canonical(voice), str(reference), "Unused original fixture"))
        assert any(v["id"] == identity for v in client.get("/v1/voices").json()["voices"])
        body["voice_id"] = identity
        assert client.delete("/v1/voices/" + identity).status_code == 200
        assert not reference.exists()
    before = client.get(route + "/cast").json()
    response = client.post(route + "/review-issues/" + issue["id"] + "/resolve", json=body)
    assert response.status_code == 409, response.text
    assert isinstance(response.json()["detail"], str)
    assert client.get(route + "/cast").json() == before
    assert client.get(route + "/review-issues").json() == inventory
    assert client.get("/v1/jobs").json()["jobs"] == [] and engine.calls == []


def test_manual_review_recovers_real_failed_analysis_without_rewriting_failure_history(review_book):
    app, client, engine, _, _, _, _ = review_book
    source = "🧭 Mira said, “Carry the lantern.”"
    response = client.post("/v1/books", files={"file": ("Original failed-model lantern.txt", source.encode())})
    assert response.status_code == 200, response.text
    book = response.json(); route = "/v1/books/" + book["id"]
    cast = {"characters": [{"id": "narrator", "name": "Narrator", "aliases": [], "voice_id": engine.id + ":narrator"}], "assignments": []}
    assert client.put(route + "/cast", json=cast).status_code == 200
    response = client.post(route + "/analyze", json={"request_id": str(uuid.uuid4()), "chapter_ids": [book["chapters"][0]["id"]]})
    assert response.status_code == 202, response.text
    failed = wait_analysis(client, response.json()["id"])
    assert failed["status"] == "failed", "This is a real unavailable analyzer, not a simulated readiness flag"
    inventory = client.get(route + "/review-issues").json()
    assert len(inventory["issues"]) == 1
    issue = inventory["issues"][0]
    assert issue["reason"] == "analysis_failed" and issue["source_text"] == "“Carry the lantern.”"
    request = selected_request(book, issue)
    assert client.post("/v1/jobs", json=request).status_code == 409
    response = client.post(route + "/review-issues/" + issue["id"] + "/resolve", json=resolve_body(inventory))
    assert response.status_code == 200, response.text
    status = client.get(route + "/analysis-status").json()["chapters"][0]
    assert status["status"] == "completed" and status["manual_ready"]
    assert "ready_for_generation" not in status, "Reviewed source coverage does not promise current voice availability"
    assert status["pending_review_count"] == 0
    assert client.get("/v1/analyses/" + failed["id"]).json() == failed
    before = len(engine.calls)
    job = render(app, client, {**request, "request_id": str(uuid.uuid4())})
    assert job["status"] == "completed", job.get("error")
    assert engine.calls[before:] == [(issue["source_text"], "mira")]
    assert client.get(route + "/source").content == source.encode()
