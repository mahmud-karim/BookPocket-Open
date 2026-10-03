"""Public synthetic transport; no model/runtime is launched by this regression."""
import json
import threading
import uuid

import httpx
from fastapi.testclient import TestClient

import bookpocket_companion.casting as casting
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config


def test_first_confirmation_returns_committed_snapshot_not_mutating_worker_job(tmp_path, monkeypatch):
    app = create_app(Config(data_dir=tmp_path, admin_token="synthetic-admin", dev=True), engines={}, start_worker=False)
    before_commit, allow_commit = threading.Event(), threading.Event()
    workers, model_calls = [], []
    original_canonical = casting.canonical
    original_start = threading.Thread.start
    original_post = httpx.Client.post

    def pause_completed_write(value):
        if (threading.current_thread().name == "casting-analysis" and isinstance(value, dict)
                and value.get("status") == "completed"):
            # The real worker has updated its mutable job object, but SQLite
            # still contains running. Do not let POST's handler return earlier.
            before_commit.set()
            assert allow_commit.wait(10), "Test did not release terminal persistence"
        return original_canonical(value)

    def start_until_terminal_write(thread):
        result = original_start(thread)
        if thread.name == "casting-analysis":
            workers.append(thread)
            assert before_commit.wait(5), "Real analysis worker never reached its terminal write"
        return result

    def original_fixture_response(client, url, **kwargs):
        if not str(url).endswith("/chat/completions"):
            return original_post(client, url, **kwargs)
        prompt = json.loads(kwargs["json"]["messages"][1]["content"])
        model_calls.append(prompt)
        result = {"characters": [{"id": "mira", "name": "Mira", "aliases": []}],
                  "assignments": [{"utterance_id": unit["utterance_id"], "source_text": unit["source_text"],
                                   "character_id": "mira", "confidence": .9} for unit in prompt["utterances"]]}
        return httpx.Response(200, request=httpx.Request("POST", url), json={"choices": [
            {"finish_reason": "stop", "message": {"content": json.dumps(result)}}]})

    monkeypatch.setattr(casting, "canonical", pause_completed_write)
    monkeypatch.setattr(threading.Thread, "start", start_until_terminal_write)
    monkeypatch.setattr(httpx.Client, "post", original_fixture_response)
    try:
        with TestClient(app, client=("127.0.0.1", 1234), headers={"Authorization": "Bearer synthetic-admin"}) as client:
            imported = client.post("/v1/books", files={"file": ("original.txt", '“The lantern is ready,” said Mira.')})
            assert imported.status_code == 200
            book = imported.json()
            assert client.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1/v1", "model": "synthetic-transport-only"}).status_code == 200
            path = f"/v1/books/{book['id']}/analyze"
            request = {"request_id": str(uuid.uuid4()), "allow_hosted": False}
            response = client.post(path, json=request)
            assert response.status_code == 202
            confirmation = response.json()
            assert before_commit.is_set() and not allow_commit.is_set()
            with app.state.store.db() as db:
                durable = json.loads(db.execute("SELECT data FROM analyses WHERE id=?", (confirmation["id"],)).fetchone()[0])
            assert durable["status"] == "running"
            assert confirmation == durable, "Initial POST must not expose uncommitted completed state"
            assert client.get("/v1/analyses/" + confirmation["id"]).json() == durable
            assert client.post(path, json=request).json() == durable
            assert len(model_calls) == len(workers) == 1
            allow_commit.set()
            workers[0].join(timeout=5)
            assert not workers[0].is_alive()
            completed = client.get("/v1/analyses/" + confirmation["id"]).json()
            assert completed["status"] == "completed"
            assert completed["id"] == confirmation["id"]
            assert confirmation["status"] == "running", "Returned snapshot must remain detached"
    finally:
        allow_commit.set()
        for worker in workers:
            worker.join(timeout=5)
