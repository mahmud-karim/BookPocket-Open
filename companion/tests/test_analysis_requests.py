"""Durable analysis submission with explicit local fixture transport only."""
import concurrent.futures
import contextlib
import json
import sqlite3
import subprocess
import sys
import threading
import time
import uuid

import httpx
import pytest
from fastapi.testclient import TestClient

from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config


def open_client(root):
    app = create_app(Config(data_dir=root, admin_token="fixture-admin", dev=True), engines={}, start_worker=False)
    return TestClient(app, client=("127.0.0.1", 9000), headers={"Authorization": "Bearer fixture-admin"}, raise_server_exceptions=False)


def terminal(client, job):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result = client.get("/v1/analyses/" + job["id"])
        assert result.status_code == 200, result.text
        job = result.json()
        if job["status"] not in {"queued", "running"}: return job
        time.sleep(.01)
    pytest.fail("Fixture analysis did not finish")


@pytest.fixture
def analysis(tmp_path, monkeypatch):
    client = open_client(tmp_path)
    book = client.post("/v1/books", files={"file": ("original.txt", '“The pilots’ maps are ready,” said Mira.')}).json()
    route = f"/v1/books/{book['id']}/analyze"
    assert client.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1234/v1", "model": "explicit-fixture-only"}).status_code == 200
    entered, release = threading.Event(), threading.Event()
    calls = []
    original_post = httpx.Client.post
    def respond(self, url, **kwargs):
        if not str(url).endswith("/chat/completions"):
            return original_post(self, url, **kwargs)
        prompt = json.loads(kwargs["json"]["messages"][1]["content"])
        calls.append(prompt)
        entered.set()
        assert release.wait(10), "Fixture transport was not released"
        result = {"characters": [{"id": "mira", "name": "Mira", "aliases": []}], "assignments": [
            {"utterance_id": unit["utterance_id"], "source_text": unit["source_text"], "character_id": "mira", "confidence": .9}
            for unit in prompt["utterances"]]}
        return httpx.Response(200, request=httpx.Request("POST", url), json={"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(result)}}]})
    monkeypatch.setattr(httpx.Client, "post", respond)
    try:
        yield client, route, entered, release, calls
    finally:
        release.set()
        client.close()


def test_simultaneous_duplicates_conflicts_terminal_and_restart(analysis, tmp_path):
    client, route, entered, release, calls = analysis
    assert {"source_ranges", "analysis_request_id"} <= set(client.get("/v1/health").json()["capabilities"])
    request = {"request_id": str(uuid.uuid4()), "allow_hosted": False}
    barrier = threading.Barrier(6)
    def submit():
        barrier.wait(timeout=5)
        return client.post(route, json=request)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        responses = list(pool.map(lambda _: submit(), range(6)))
    assert all(response.status_code == 202 for response in responses), [r.text for r in responses]
    job = responses[0].json()
    assert {r.json()["id"] for r in responses} == {job["id"]}
    assert entered.wait(5) and len(calls) == 1
    assert client.post(route, json={**request, "allow_hosted": True}).status_code == 409
    assert client.post("/v1/books/different-book/analyze", json=request).status_code == 409
    next_request = {"request_id": str(uuid.uuid4())}
    assert client.post(route, json=next_request).status_code == 409
    release.set()
    completed = terminal(client, job)
    assert completed["status"] == "completed"
    assert client.post(route, json=request).json() == completed
    # Reconstruct only after the original process has released its worker
    # lease; retrying a known UUID above still remains nonblocking.
    client.app.state.scheduler.join()
    # Identity uses normalized UUID and captured consent, never mutable settings.
    client.put("/v1/admin/analyzer", json={"url": "https://different.example/v1", "model": "changed"})
    assert client.post(route, json={**request, "request_id": request["request_id"].upper()}).json() == completed
    (tmp_path / "analyzer.json").unlink()
    with open_client(tmp_path) as reconstructed:
        assert reconstructed.post(route, json=request).json() == completed
        assert reconstructed.post(route, json={**request, "allow_hosted": True}).status_code == 409
        assert len(calls) == 1
        reconstructed.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1234/v1", "model": "explicit-fixture-only"})
        new = reconstructed.post(route, json=next_request)
        assert new.status_code == 202 and new.json()["id"] != job["id"]
        assert terminal(reconstructed, new.json())["status"] == "completed"
        assert len(calls) == 2


def test_legacy_submissions_remain_fresh_and_invalid_uuid_rejected(analysis):
    client, route, _, release, calls = analysis
    assert client.post(route, json={"request_id": "not-a-uuid"}).status_code == 422
    release.set()
    response = client.post(route, json={})
    assert response.status_code == 202, response.text
    first = terminal(client, response.json())
    # Completion commits atomically with the cast before the model worker's
    # actual lease release. This test submits fresh work after that release;
    # accepting a terminal snapshot does not bypass heavy-work serialization.
    client.app.state.scheduler.join()
    response = client.post(route, json={"request_id": None})
    assert response.status_code == 202, response.text
    second = terminal(client, response.json())
    assert first["status"] == second["status"] == "completed"
    assert first["id"] != second["id"] and len(calls) == 2


def test_request_mapping_survives_abrupt_process_exit_without_relaunching_model(analysis, tmp_path):
    client, route, _, _, calls = analysis
    request = {"request_id": str(uuid.uuid4()), "allow_hosted": False}
    child = r'''
import httpx, os, sys, time
from pathlib import Path
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
app = create_app(Config(data_dir=Path(sys.argv[1]), admin_token="fixture-admin", dev=True), engines={}, start_worker=False)
original = httpx.Client.post
def stop_at_transport(self, url, **kwargs):
    if str(url).endswith("/chat/completions"): os._exit(77)
    return original(self, url, **kwargs)
httpx.Client.post = stop_at_transport
with TestClient(app, client=("127.0.0.1", 9000), headers={"Authorization": "Bearer fixture-admin"}) as client:
    response = client.post(sys.argv[2], json={"request_id": sys.argv[3], "allow_hosted": False})
    assert response.status_code == 202, response.text
    time.sleep(10)
raise SystemExit("Fixture analysis did not reach the crash boundary")
'''
    result = subprocess.run([sys.executable, "-c", child, str(tmp_path), route, request["request_id"]], capture_output=True, text=True, timeout=15)
    assert result.returncode == 77, result.stderr
    with client.app.state.store.db() as db:
        mapping = db.execute("SELECT analysis_id FROM analysis_requests WHERE request_id=?", (request["request_id"],)).fetchone()
        crashed = json.loads(db.execute("SELECT data FROM analyses WHERE id=?", (mapping[0],)).fetchone()[0])
    assert crashed["status"] == "running"
    assert crashed["stage"] == "analyzing" and crashed["completed_segments"] == 0
    (tmp_path / "analyzer.json").unlink()
    with open_client(tmp_path) as reconstructed:
        replay = reconstructed.post(route, json=request)
        assert replay.status_code == 202
        assert replay.json()["id"] == crashed["id"]
        assert replay.json()["status"] == "failed" and "restart" in replay.json()["error"]
        assert replay.json()["stage"] == "failed" and replay.json()["completed_segments"] == 0
        assert reconstructed.post(route, json=request).json() == replay.json()
    assert not calls


def test_thread_start_failure_is_durable_and_releases_global_lock(analysis, monkeypatch, tmp_path):
    client, route, _, release, calls = analysis
    original_start = threading.Thread.start
    def fail_start(thread):
        if thread.name == "casting-analysis": raise RuntimeError("Injected fixture thread-start failure")
        return original_start(thread)
    monkeypatch.setattr(threading.Thread, "start", fail_start)
    request = {"request_id": str(uuid.uuid4())}
    response = client.post(route, json=request)
    assert response.status_code == 202
    failed = response.json()
    assert failed["status"] == "failed" and "start" in failed["error"]
    assert client.post(route, json=request).json() == failed
    monkeypatch.setattr(threading.Thread, "start", original_start)
    release.set()
    assert terminal(client, client.post(route, json={"request_id": str(uuid.uuid4())}).json())["status"] == "completed"
    with open_client(tmp_path) as reconstructed:
        assert reconstructed.post(route, json=request).json() == failed
    assert len(calls) == 1


def inject_sql_failure(monkeypatch, store, predicate):
    original_db = store.db
    @contextlib.contextmanager
    def database():
        with original_db() as db:
            class Connection:
                def execute(self, sql, parameters=()):
                    if predicate(sql, parameters): raise sqlite3.OperationalError("Injected fixture storage failure")
                    return db.execute(sql, parameters)
            yield Connection()
    monkeypatch.setattr(store, "db", database)


def test_registration_failure_rolls_back_both_rows_and_releases_lock(analysis, monkeypatch):
    client, route, _, release, calls = analysis
    failures = []
    def fail_once(sql, parameters):
        if sql.startswith("INSERT INTO analysis_requests") and not failures:
            failures.append(True)
            return True
        return False
    store = client.app.state.store
    inject_sql_failure(monkeypatch, store, fail_once)
    request = {"request_id": str(uuid.uuid4())}
    assert client.post(route, json=request).status_code == 500
    with store.db() as db:
        assert db.execute("SELECT count(*) FROM analyses").fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM analysis_requests").fetchone()[0] == 0
    release.set()
    assert terminal(client, client.post(route, json=request).json())["status"] == "completed"
    assert len(calls) == 1


def test_terminal_write_failure_cannot_leave_a_false_running_job_or_locked_analyzer(analysis, monkeypatch, tmp_path):
    client, route, entered, release, calls = analysis
    failures = []
    def fail_terminal_writes(sql, parameters):
        if sql.startswith("UPDATE analyses SET data=") and json.loads(parameters[0])["status"] in {"completed", "failed"} and len(failures) < 2:
            failures.append(True)
            return True
        return False
    inject_sql_failure(monkeypatch, client.app.state.store, fail_terminal_writes)
    request = {"request_id": str(uuid.uuid4())}
    response = client.post(route, json=request)
    assert response.status_code == 202 and entered.wait(5)
    worker = next(thread for thread in threading.enumerate() if thread.name == "casting-analysis")
    release.set()
    # Both injected failures belong to worker finalization. Polling earlier can
    # consume the second failure in the recovery write instead, changing the
    # fault scenario and making this test depend on host thread scheduling.
    worker.join(timeout=5)
    assert not worker.is_alive() and len(failures) == 2
    failed = terminal(client, response.json())
    assert failed["status"] == "failed" and "save analysis status" in failed["error"]
    assert len(failures) == 2 and client.post(route, json=request).json() == failed
    assert terminal(client, client.post(route, json={"request_id": str(uuid.uuid4())}).json())["status"] == "completed"
    with open_client(tmp_path) as reconstructed:
        assert reconstructed.post(route, json=request).json() == failed
    assert len(calls) == 2
