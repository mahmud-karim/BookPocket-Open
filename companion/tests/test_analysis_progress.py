"""Actual durable progress boundaries with explicit, blocked classifier fixtures.

These tests exercise source parsing, scheduler admission, validation, merge and
SQLite commits. The fixture classifier does not claim to be a live Gemini call.
"""
import json
import threading
import uuid
from pathlib import Path

import pytest

from bookpocket_companion import antigravity_analyzer as agy
from bookpocket_companion import casting
from test_analysis_requests import open_client, terminal, inject_sql_failure


def request(chapter_id):
    return {"request_id": str(uuid.uuid4()), "chapter_ids": [chapter_id], "allow_hosted": True}


def upload(client, text):
    response = client.post("/v1/books", files={"file": ("original-progress-fixture.txt", text)})
    assert response.status_code == 200, response.text
    book = response.json()
    return book, f"/v1/books/{book['id']}/analyze"


def configure(client, monkeypatch, budget=1200):
    monkeypatch.setattr(agy, "readiness", lambda _: {"ready": True, "authentication_checked": False})
    response = client.put("/v1/admin/analyzer", json={"provider": "antigravity", "url": "", "api_key": "",
        "model": agy.MODEL, "max_output_tokens": budget})
    assert response.status_code == 200, response.text


def classified(prompt):
    return {"characters": [{"id": "mira", "name": "Mira", "aliases": []}], "assignments": [
        {"utterance_id": unit["utterance_id"], "source_text": unit["source_text"],
         "character_id": "mira", "confidence": .9} for unit in prompt["utterances"]]}


def stored(client, identity):
    with client.app.state.store.db() as db:
        return json.loads(db.execute("SELECT data FROM analyses WHERE id=?", (identity,)).fetchone()[0])


def test_persisted_admission_batch_progress_and_atomic_terminal_commit(tmp_path, monkeypatch):
    client = open_client(tmp_path)
    configure(client, monkeypatch)
    original = "\n\n".join(f'“The lantern number {n} is ready,” said Mira. ' +
        "The light fell across the map while the travelers waited quietly at the window." for n in range(3))
    book, route = upload(client, original)
    chapter = book["chapters"][0]
    assert len(chapter["segments"]) == 3
    entered = [threading.Event() for _ in range(3)]
    released = [threading.Event() for _ in range(3)]
    saving, commit = threading.Event(), threading.Event()
    reading, read = threading.Event(), threading.Event()
    held, admitted = threading.Event(), threading.Event()
    calls = []
    original_scan = casting.scan_dialogue
    def pause_reading(segments):
        if threading.current_thread().name == "casting-analysis" and not reading.is_set():
            reading.set()
            assert read.wait(10)
        return original_scan(segments)
    monkeypatch.setattr(casting, "scan_dialogue", pause_reading)
    def classify(cfg, instruction, prompt, schema, **kwargs):
        assert cfg["model"] == "gemini-3.8-flash-high" and cfg["hosted"] is True
        index = len(calls)
        calls.append(prompt)
        entered[index].set()
        assert released[index].wait(10)
        return classified(prompt)
    monkeypatch.setattr(agy, "classify", classify)
    review = client.app.state.cast_review
    original_status = review.chapter_status
    def pause_before_commit(*args, **kwargs):
        if threading.current_thread().name == "casting-analysis" and len(calls) == 3:
            saving.set()
            assert commit.wait(10)
        return original_status(*args, **kwargs)
    monkeypatch.setattr(review, "chapter_status", pause_before_commit)
    def hold_model_lease():
        with client.app.state.scheduler.lease("explicit-test-holder"):
            held.set()
            assert admitted.wait(10)
    holder = threading.Thread(target=hold_model_lease)
    holder.start()
    assert held.wait(5)
    body = request(chapter["id"])
    try:
        assert client.post(route, json={**body, "allow_hosted": False}).status_code == 409
        response = client.post(route, json=body)
        assert response.status_code == 202, response.text
        job = response.json()
        assert (job["status"], job["stage"], job["completed_segments"], job["total_segments"]) == ("queued", "queued", 0, 3)
        assert client.post(route, json=body).json() == stored(client, job["id"])
        coverage = client.get(f"/v1/books/{book['id']}/analysis-status").json()["chapters"][0]
        assert coverage["status"] == "queued" and coverage["analysis_id"] == job["id"]
        admitted.set()
        assert reading.wait(5)
        initial = client.get("/v1/analyses/" + job["id"]).json()
        assert initial == stored(client, job["id"])
        assert initial["stage"] == "reading" and initial["status"] == "running"
        assert initial["completed_segments"] == 0 and initial["total_batches"] is None
        read.set()
        assert entered[0].wait(5)
        for index in range(3):
            assert entered[index].wait(5)
            progress = client.get("/v1/analyses/" + job["id"]).json()
            assert progress == stored(client, job["id"])
            assert progress["status"] == "running" and progress["stage"] == "analyzing"
            assert progress["completed_segments"] == progress["completed_batches"] == index
            assert progress["total_segments"] == progress["total_batches"] == 3
            assert progress["current_chapter_id"] == chapter["id"]
            assert progress["current_chapter_title"] == chapter["title"]
            assert progress["current_chapter_index"] == progress["total_chapters"] == 1
            assert client.post(route, json=body).json() == progress
            released[index].set()
        assert saving.wait(5)
        before_commit = client.get("/v1/analyses/" + job["id"]).json()
        assert before_commit["status"] == "running" and before_commit["stage"] == "saving"
        assert before_commit["completed_segments"] == before_commit["total_segments"] == 3
        assert before_commit["completed_batches"] == before_commit["total_batches"] == 3
        assert before_commit["chapter_statuses"][0]["status"] == "running"
        assert client.get(f"/v1/books/{book['id']}/cast").json()["assignments"] == []
        commit.set()
        complete = terminal(client, job)
        assert complete["stage"] == "completed" and complete["chapter_statuses"][0]["status"] == "completed"
        cast = client.get(f"/v1/books/{book['id']}/cast").json()
        assert len(cast["assignments"]) == 3
        assert all(not assignment["reviewed"] for assignment in cast["assignments"])
        assert client.get(f"/v1/books/{book['id']}").json()["chapters"] == book["chapters"]
        cached = client.post(route, json=request(chapter["id"])).json()
        assert cached["status"] == cached["stage"] == "completed"
        assert cached["completed_segments"] == cached["total_segments"] == 3
        assert cached["reused_chapter_ids"] == [chapter["id"]] and len(calls) == 3
        with open_client(tmp_path) as reconstructed:
            assert reconstructed.post(route, json=body).json() == complete
    finally:
        admitted.set()
        read.set()
        for event in released: event.set()
        commit.set()
        holder.join(5)
        client.app.state.scheduler.join()
        client.close()


def test_narration_only_is_counted_without_model_and_empty_chapter_completes(tmp_path, monkeypatch):
    with open_client(tmp_path) as client:
        def forbidden(*args, **kwargs):
            pytest.fail("Narration-only work must never call the classifier")
        monkeypatch.setattr(agy, "classify", forbidden)
        book, route = upload(client, "The lantern glowed at the window.\n\nMira waited for sunrise.")
        chapter = book["chapters"][0]
        job = terminal(client, client.post(route, json=request(chapter["id"])).json())
        assert job["status"] == job["stage"] == "completed"
        assert job["completed_segments"] == job["total_segments"] == 2
        assert job["completed_batches"] == job["total_batches"] == 1
        assert job["review_required"] is False
        # Completion is committed before the worker releases its heavy lease.
        # The next, unrelated fixture mutation waits for that actual shutdown.
        client.app.state.scheduler.join()
        # Explicit test-only manifest boundary: an empty original chapter has no
        # source work, model request, assignment or percentage to fabricate.
        book["chapters"][0]["segments"] = []
        with client.app.state.store.db() as db:
            db.execute("UPDATE books SET data=? WHERE id=?", (json.dumps(book), book["id"]))
        empty = terminal(client, client.post(route, json={**request(chapter["id"]), "force_reanalyze": True}).json())
        assert empty["status"] == empty["stage"] == "completed"
        assert empty["completed_segments"] == empty["total_segments"] == 0
        assert empty["completed_batches"] == empty["total_batches"] == 0


def test_oversized_manual_review_source_is_processed_without_model_success(tmp_path, monkeypatch):
    with open_client(tmp_path) as client:
        configure(client, monkeypatch, budget=256)
        monkeypatch.setattr(agy, "classify", lambda *a, **k: pytest.fail("Budget-excluded paragraph must not call model"))
        book, route = upload(client, '“' + 'The lantern glowed. ' * 40 + '” said Mira.')
        job = terminal(client, client.post(route, json=request(book["chapters"][0]["id"])).json())
        assert job["status"] == job["stage"] == "completed"
        assert job["completed_segments"] == job["total_segments"] == 1
        assert job["completed_batches"] == job["total_batches"] == 0
        assert job["review_required"] is True
        assert client.get(f"/v1/books/{book['id']}/cast").json()["assignments"] == []


def test_invalid_model_output_does_not_count_failed_batch(tmp_path, monkeypatch):
    with open_client(tmp_path) as client:
        configure(client, monkeypatch)
        def invalid(cfg, instruction, prompt, schema, **kwargs):
            result = classified(prompt)
            result["assignments"][0]["source_text"] = "rewritten fixture text"
            return result
        monkeypatch.setattr(agy, "classify", invalid)
        book, route = upload(client, '“The lantern is ready,” said Mira.')
        body = request(book["chapters"][0]["id"])
        failed = terminal(client, client.post(route, json=body).json())
        assert failed["status"] == failed["stage"] == "failed"
        assert failed["completed_segments"] == failed["completed_batches"] == 0
        assert failed["total_segments"] == failed["total_batches"] == 1
        assert "exact utterance" in failed["error"]
        assert failed["chapter_statuses"][0]["status"] == "failed"
        assert client.post(route, json=body).json() == failed
        assert client.get(f"/v1/books/{book['id']}/cast").json()["assignments"] == []


def test_failed_terminal_transaction_cannot_publish_completed_chapter(tmp_path, monkeypatch):
    with open_client(tmp_path) as client:
        configure(client, monkeypatch)
        monkeypatch.setattr(agy, "classify", lambda cfg, instruction, prompt, schema, **kwargs: classified(prompt))
        book, route = upload(client, '“The lantern is ready,” said Mira.')
        failures = []
        def reject_completed_write(sql, parameters):
            if sql.startswith("UPDATE analyses SET data=") and json.loads(parameters[0])["status"] == "completed" and not failures:
                failures.append(True)
                return True
            return False
        inject_sql_failure(monkeypatch, client.app.state.store, reject_completed_write)
        body = request(book["chapters"][0]["id"])
        failed = terminal(client, client.post(route, json=body).json())
        assert failures and failed["status"] == failed["stage"] == "failed"
        assert failed["completed_segments"] == failed["total_segments"] == 1
        assert failed["chapter_statuses"][0]["status"] == "failed"
        assert client.get(f"/v1/books/{book['id']}/cast").json()["assignments"] == []
        assert client.post(route, json=body).json() == failed
        with open_client(tmp_path) as reconstructed:
            assert reconstructed.get("/v1/analyses/" + failed["id"]).json() == failed


def test_active_chapter_discovery_survives_config_change_without_new_submission(tmp_path, monkeypatch):
    client = open_client(tmp_path)
    configure(client, monkeypatch, budget=4096)
    entered, release = threading.Event(), threading.Event()
    calls = []
    def classify(cfg, instruction, prompt, schema, **kwargs):
        assert cfg["model"] == agy.MODEL and cfg["max_output_tokens"] == 4096
        calls.append(prompt)
        entered.set()
        assert release.wait(10)
        return classified(prompt)
    monkeypatch.setattr(agy, "classify", classify)
    source = (Path(__file__).parents[2] / "tests/fixtures/lantern.epub").read_bytes()
    book = client.post("/v1/books", files={"file": ("lantern.epub", source, "application/epub+zip")}).json()
    chapters = [c for c in book["chapters"] if any("\u201c" in s["text"] for s in c["segments"])]
    assert len(chapters) >= 2
    other, _ = upload(client, '“A different book,” said Mira.')
    body = request(chapters[0]["id"])
    route = f"/v1/books/{book['id']}/analyze"
    try:
        job = client.post(route, json=body).json()
        assert entered.wait(5)
        configure(client, monkeypatch, budget=5000)
        # Newer irrelevant rows must not shadow the accepted active analysis.
        active = stored(client, job["id"])
        variants = [{"source_sha256": "different-source"}, {"book_id": other["id"]},
                    {"chapter_ids": ["different-chapter"]}, {"status": "completed"}]
        with client.app.state.store.db() as db:
            for n, changes in enumerate(variants):
                decoy = {**active, **changes, "id": f"test-only-unrelated-progress-{n}", "created_at": "9999-01-01"}
                db.execute("INSERT INTO analyses VALUES(?,?)", (decoy["id"], json.dumps(decoy)))
        states = client.get(f"/v1/books/{book['id']}/analysis-status").json()["chapters"]
        running = next(s for s in states if s["chapter_id"] == chapters[0]["id"])
        assert running["status"] == "running" and running["analysis_id"] == job["id"]
        untouched = next(s for s in states if s["chapter_id"] == chapters[1]["id"])
        assert untouched["status"] == "not_analyzed" and "analysis_id" not in untouched
        assert client.post(route, json=body).json()["id"] == job["id"] and len(calls) == 1
        release.set()
        assert terminal(client, job)["stage"] == "completed"
        with client.app.state.store.db() as db:
            db.execute("DELETE FROM analyses WHERE id LIKE 'test-only-unrelated-progress-%'")
        # Different-config completed work is not advertised as active recovery.
        final = client.get(f"/v1/books/{book['id']}/analysis-status").json()["chapters"]
        assert next(s for s in final if s["chapter_id"] == chapters[0]["id"])["status"] == "not_analyzed"
    finally:
        release.set()
        client.app.state.scheduler.join()
        client.close()


def test_reviewed_coverage_does_not_hide_actual_force_reanalysis(tmp_path, monkeypatch):
    with open_client(tmp_path) as client:
        configure(client, monkeypatch)
        entered, release = threading.Event(), threading.Event()
        def classify(cfg, instruction, prompt, schema, **kwargs):
            entered.set()
            assert release.wait(10)
            return classified(prompt)
        monkeypatch.setattr(agy, "classify", classify)
        book, route = upload(client, '“The lantern is ready,” said Mira.')
        chapter = book["chapters"][0]
        segment = chapter["segments"][0]
        saved = {"characters": [{"id": "narrator", "name": "Narrator"}, {"id": "mira", "name": "Mira"}],
            "assignments": [{"id": "test-only-human-choice", "segment_id": segment["id"],
                "start_offset": 0, "end_offset": segment["text"].index("\u201d")+1,
                "character_id": "mira", "confidence": 1, "reviewed": True}]}
        assert client.put(f"/v1/books/{book['id']}/cast", json=saved).status_code == 200
        try:
            job = client.post(route, json={**request(chapter["id"]), "force_reanalyze": True}).json()
            assert entered.wait(5)
            state = client.get(f"/v1/books/{book['id']}/analysis-status").json()["chapters"][0]
            assert state["manual_ready"] is True
            assert state["status"] == "running" and state["analysis_id"] == job["id"]
            release.set()
            assert terminal(client, job)["stage"] == "completed"
            assert client.get(f"/v1/books/{book['id']}/cast").json()["assignments"] == saved["assignments"]
        finally:
            release.set()
            client.app.state.scheduler.join()


def test_mixed_cached_chapters_count_actual_source_and_current_chapter_batches(tmp_path, monkeypatch):
    with open_client(tmp_path) as client:
        configure(client, monkeypatch, budget=4096)
        entered, release = threading.Event(), threading.Event()
        calls = []
        def classify(cfg, instruction, prompt, schema, **kwargs):
            calls.append(prompt)
            if len(calls) == 2:
                entered.set()
                assert release.wait(10)
            return classified(prompt)
        monkeypatch.setattr(agy, "classify", classify)
        source = (Path(__file__).parents[2] / "tests/fixtures/lantern.epub").read_bytes()
        book = client.post("/v1/books", files={"file": ("lantern.epub", source, "application/epub+zip")}).json()
        chapters = [c for c in book["chapters"] if any("\u201c" in s["text"] for s in c["segments"])][:2]
        assert len(chapters) == 2
        route = f"/v1/books/{book['id']}/analyze"
        response = client.post(route, json=request(chapters[0]["id"]))
        assert response.status_code == 202, response.text
        first = terminal(client, response.json())
        assert first["stage"] == "completed"
        assert first["completed_segments"] == len(chapters[0]["segments"])
        # The next request includes uncached work, so wait for the previous
        # worker's lease release rather than only its committed snapshot.
        client.app.state.scheduler.join()
        try:
            body = {**request(chapters[0]["id"]), "chapter_ids": [c["id"] for c in reversed(chapters)]}
            response = client.post(route, json=body)
            assert response.status_code == 202, response.text
            job = response.json()
            assert entered.wait(5)
            active = client.get("/v1/analyses/" + job["id"]).json()
            assert active["chapter_ids"] == [c["id"] for c in chapters], "Progress follows publication order"
            assert active["reused_chapter_ids"] == [chapters[0]["id"]]
            assert active["current_chapter_id"] == chapters[1]["id"]
            assert active["current_chapter_index"] == active["total_chapters"] == 2
            assert active["completed_segments"] == len(chapters[0]["segments"])
            assert active["total_segments"] == sum(len(c["segments"]) for c in chapters)
            assert active["completed_batches"] == 0 and active["total_batches"] == 1
            assert [s["status"] for s in active["chapter_statuses"]] == ["completed", "running"]
            release.set()
            complete = terminal(client, job)
            assert complete["stage"] == "completed" and complete["completed_segments"] == complete["total_segments"]
            assert complete["completed_batches"] == complete["total_batches"] == 1 and len(calls) == 2
        finally:
            release.set()
            client.app.state.scheduler.join()


@pytest.mark.parametrize("status,stage", [("queued", "queued"), ("running", "reading"), ("running", "saving")])
def test_restart_reports_failed_stage_without_manufacturing_finished_work(tmp_path, status, stage):
    with open_client(tmp_path) as client:
        book, _ = upload(client, '“The lantern is ready,” said Mira.')
        # Explicit durable crash fixture; no worker is run for this accepted job.
        job = {"id": str(uuid.uuid4()), "book_id": book["id"], "status": status, "stage": stage,
            "completed_segments": 0, "total_segments": 1, "completed_batches": 0, "total_batches": 1,
            "chapter_statuses": [{"chapter_id": book["chapters"][0]["id"], "status": status}]}
        with client.app.state.store.db() as db:
            db.execute("INSERT INTO analyses VALUES(?,?)", (job["id"], json.dumps(job)))
    with open_client(tmp_path) as reconstructed:
        failed = reconstructed.get("/v1/analyses/" + job["id"]).json()
        assert failed["status"] == failed["stage"] == "failed" and "restart" in failed["error"]
        assert failed["completed_segments"] == failed["completed_batches"] == 0
        assert failed["total_segments"] == failed["total_batches"] == 1
        assert failed["chapter_statuses"][0]["status"] == "failed"
