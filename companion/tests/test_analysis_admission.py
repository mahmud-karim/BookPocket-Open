"""Deterministic terminal-commit race using original fixture text and fake transport."""
from contextlib import contextmanager
import json
from pathlib import Path
import threading
import uuid

import httpx
import pytest
from fastapi.testclient import TestClient

from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config


@pytest.mark.parametrize("first_status", ["completed", "failed"])
def test_terminal_commit_allows_next_analysis_before_prior_thread_exits(tmp_path, monkeypatch, first_status):
    app = create_app(Config(data_dir=tmp_path, admin_token="admission-fixture", dev=True), engines={}, start_worker=False)
    committed, leave_commit = threading.Event(), threading.Event()
    second_entered, finish_second = threading.Event(), threading.Event()
    first_workers, calls = [], []
    original_db, original_post = app.state.store.db, httpx.Client.post

    @contextmanager
    def pause_after_terminal_commit():
        terminal_write = False
        with original_db() as db:
            class Connection:
                def execute(self, sql, parameters=()):
                    nonlocal terminal_write
                    if (threading.current_thread().name == "casting-analysis" and not committed.is_set()
                            and sql.startswith("UPDATE analyses SET data=")
                            and json.loads(parameters[0]).get("status") == first_status):
                        terminal_write = True
                    return db.execute(sql, parameters)
                def __getattr__(self, name): return getattr(db, name)
            yield Connection()
        # SQLite has really committed and released its writer lock. Freeze the
        # worker at exactly the boundary the API can now observe as terminal.
        if terminal_write:
            first_workers.append(threading.current_thread())
            committed.set()
            assert leave_commit.wait(10), "Fixture did not release the completed write"

    def respond(client, url, **kwargs):
        if not str(url).endswith("/chat/completions"): return original_post(client, url, **kwargs)
        prompt = json.loads(kwargs["json"]["messages"][1]["content"])
        calls.append(prompt)
        if len(calls) == 1 and first_status == "failed":
            return httpx.Response(503, request=httpx.Request("POST", url), json={"error": "Explicit fixture failure"})
        if len(calls) == 2:
            second_entered.set()
            assert finish_second.wait(10), "Fixture did not release second model call"
        answer = {"characters": [{"id": "mira", "name": "Mira", "aliases": []}],
                  "assignments": [{"utterance_id": u["utterance_id"], "source_text": u["source_text"],
                                   "character_id": "mira", "confidence": .8} for u in prompt["utterances"]]}
        return httpx.Response(200, request=httpx.Request("POST", url), json={"choices": [
            {"finish_reason": "stop", "message": {"content": json.dumps(answer)}}]})

    monkeypatch.setattr(app.state.store, "db", pause_after_terminal_commit)
    monkeypatch.setattr(httpx.Client, "post", respond)
    try:
        with TestClient(app, client=("127.0.0.1", 1234), headers={"Authorization": "Bearer admission-fixture"}) as client:
            source = Path(__file__).resolve().parents[2] / "tests/fixtures/lantern.epub"
            with source.open("rb") as file:
                imported = client.post("/v1/books", files={"file": ("lantern.epub", file, "application/epub+zip")})
            assert imported.status_code == 200, imported.text
            book = imported.json()
            chapters = [c for c in book["chapters"] if any("“" in s["text"] for s in c["segments"])]
            assert len(chapters) >= 2
            route = f"/v1/books/{book['id']}"
            assert client.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1/v1", "model": "admission-fixture-only"}).status_code == 200
            first_request = {"request_id": str(uuid.uuid4()), "chapter_ids": [chapters[0]["id"]]}
            first = client.post(route + "/analyze", json=first_request)
            assert first.status_code == 202 and committed.wait(5), first.text
            finished = client.get("/v1/analyses/" + first.json()["id"]).json()
            assert finished["status"] == first_status
            assert first_workers[0].is_alive()
            assert client.post(route + "/analyze", json=first_request).json() == finished
            saved = client.get(route + "/cast").json()
            if first_status == "completed":
                assert saved["assignments"]
                saved["assignments"][0]["reviewed"] = True
                assert client.put(route + "/cast", json=saved).status_code == 200
            second = client.post(route + "/analyze", json={"request_id": str(uuid.uuid4()), "chapter_ids": [chapters[1]["id"]]})
            assert second.status_code == 202, second.text
            if first_status == "completed":
                assert second.json()["status"] == "queued"
                assert len(calls) == 1, "Model work must still wait for the first scheduler lease"
            leave_commit.set()
            assert second_entered.wait(5)
            first_workers[0].join(timeout=5)
            assert not first_workers[0].is_alive()
            # Old finalization must not release the next analysis's lock.
            third = client.post(route + "/analyze", json={"request_id": str(uuid.uuid4()), "chapter_ids": [chapters[0]["id"]], "force_reanalyze": True})
            assert third.status_code == 409 and "Another casting analysis" in third.text
            finish_second.set()
            app.state.scheduler.join()
            assert client.get("/v1/analyses/" + second.json()["id"]).json()["status"] == "completed"
            assert len(calls) == 2
            if first_status == "completed":
                assert saved["assignments"][0] in client.get(route + "/cast").json()["assignments"]
    finally:
        leave_commit.set()
        finish_second.set()
        app.state.scheduler.join()
