"""Actual API/worker admission with explicit blocking test-only model fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid
import wave

import httpx
import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.engines import ManagedEngine
from bookpocket_companion.models import Config
from bookpocket_companion.scheduler import WorkCancelled, WorkOwnershipUncertain
from bookpocket_companion.setup_process import run_setup


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(.01)
    pytest.fail("Fixture condition did not become true")


class Tracker:
    def __init__(self):
        self.entered = {kind: threading.Event() for kind in ("render", "analysis", "install")}
        self.release = {kind: threading.Event() for kind in self.entered}
        self.lock = threading.Lock()
        self.active, self.maximum = 0, 0
        self.fail = None

    def call(self, kind):
        with self.lock:
            self.active += 1
            self.maximum = max(self.maximum, self.active)
        self.entered[kind].set()
        try:
            assert self.release[kind].wait(10), "Fixture call was not released"
            if self.fail == kind: raise RuntimeError("Explicit fixture failure")
        finally:
            with self.lock: self.active -= 1


class BlockingEngine(ManagedEngine):
    version = "explicit-test-fixture"
    def __init__(self, root, tracker):
        super().__init__(root, "fixture")
        self.tracker = tracker
    def info(self):
        return {"id": self.id, "name": "Explicit fixture", "available": True, "languages": ["en"]}
    def voices(self):
        return [{"id": "fixture:voice", "name": "Fixture narrator", "engine": self.id}]
    def synthesize(self, text, voice, output, language):
        self.tracker.call("render")
        with wave.open(str(output), "wb") as wav:
            wav.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\1\0" * 2400)
    def install(self, cancel_event=None):
        self.tracker.call("install")


@pytest.fixture
def scheduled(tmp_path, monkeypatch):
    tracker = Tracker()
    engine = BlockingEngine(tmp_path / "engines", tracker)
    app = create_app(Config(data_dir=tmp_path, admin_token="fixture", dev=True), engines={engine.id: engine})
    original_post = httpx.Client.post
    def respond(self, url, **kwargs):
        if not str(url).endswith("/chat/completions"):
            return original_post(self, url, **kwargs)
        tracker.call("analysis")
        prompt = json.loads(kwargs["json"]["messages"][1]["content"])
        result = {"characters": [{"id": "mira", "name": "Mira", "aliases": []}], "assignments": [
            {"utterance_id": u["utterance_id"], "source_text": u["source_text"], "character_id": "mira", "confidence": .9} for u in prompt["utterances"]]}
        return httpx.Response(200, request=httpx.Request("POST", url), json={"choices": [{"message": {"content": json.dumps(result)}}]})
    monkeypatch.setattr(httpx.Client, "post", respond)
    with TestClient(app, client=("127.0.0.1", 9000), headers={"Authorization": "Bearer fixture"}) as client:
        book = client.post("/v1/books", files={"file": ("original.txt", '“Ready,” said Mira.')}).json()
        client.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1234/v1", "model": "explicit-fixture"})
        def submit(kind):
            if kind == "render":
                response = client.post("/v1/jobs", json={"request_id": str(uuid.uuid4()), "book_id": book["id"], "segment_ids": [s["id"] for c in book["chapters"] for s in c["segments"]], "engine": engine.id, "voice_id": "fixture:voice"})
                assert response.status_code == 202, response.text
                identity = response.json()["id"]
                return lambda: client.get("/v1/jobs/" + identity).json()
            if kind == "analysis":
                request = {"request_id": str(uuid.uuid4())}
                route = f"/v1/books/{book['id']}/analyze"
                response = client.post(route, json=request)
                assert response.status_code == 202, response.text
                assert client.post(route, json=request).json()["id"] == response.json()["id"]
                identity = response.json()["id"]
                return lambda: client.get("/v1/analyses/" + identity).json()
            response = client.post("/v1/admin/engines/fixture/install")
            assert response.status_code == 200, response.text
            return lambda: client.get("/v1/admin/engines/installations").json()["installations"][0]
        try: yield app, client, tracker, submit
        finally:
            for event in tracker.release.values(): event.set()
            wait_for(lambda: tracker.active == 0)


@pytest.mark.parametrize("first,second", [(a, b) for a in ("render", "analysis", "install") for b in ("render", "analysis", "install") if a != b])
def test_all_heavy_work_pairs_wait_for_actual_slot_in_both_directions(scheduled, first, second):
    _, _, tracker, submit = scheduled
    first_state = submit(first)
    assert tracker.entered[first].wait(5)
    started = time.monotonic()
    second_state = submit(second)
    assert time.monotonic() - started < 1
    assert second_state()["status"] == "queued"
    assert not tracker.entered[second].wait(.15)
    tracker.release[first].set()
    assert tracker.entered[second].wait(5)
    assert second_state()["status"] == "running"
    tracker.release[second].set()
    wait_for(lambda: first_state()["status"] == second_state()["status"] == "completed")
    assert tracker.maximum == 1


@pytest.mark.parametrize("action", ["pause", "cancel"])
@pytest.mark.parametrize("next_kind", ["analysis", "install"])
def test_paused_or_cancelled_inflight_render_keeps_slot_until_model_returns(scheduled, action, next_kind):
    _, client, tracker, submit = scheduled
    render = submit("render")
    assert tracker.entered["render"].wait(5)
    assert client.post(f'/v1/jobs/{render()["id"]}/{action}').status_code == 200
    following = submit(next_kind)
    assert following()["status"] == "queued"
    assert not tracker.entered[next_kind].wait(.15)
    tracker.release["render"].set()
    assert tracker.entered[next_kind].wait(5)
    tracker.release[next_kind].set()
    wait_for(lambda: following()["status"] == "completed")
    assert render()["status"] == ("paused" if action == "pause" else "cancelled")
    assert render()["assets"] == [] and tracker.maximum == 1


@pytest.mark.parametrize("kind", ["render", "analysis", "install"])
def test_failure_releases_the_actual_slot(scheduled, kind):
    _, _, tracker, submit = scheduled
    tracker.fail = kind
    first = submit(kind)
    assert tracker.entered[kind].wait(5)
    next_kind = "analysis" if kind != "analysis" else "render"
    following = submit(next_kind)
    tracker.release[kind].set()
    assert tracker.entered[next_kind].wait(5)
    tracker.release[next_kind].set()
    wait_for(lambda: first()["status"] == "failed" and following()["status"] == "completed")
    assert tracker.maximum == 1


def test_shutdown_with_pending_work_never_admits_it(scheduled):
    app, _, tracker, submit = scheduled
    active = submit("analysis")
    assert tracker.entered["analysis"].wait(5)
    queued = submit("install")
    render = submit("render")
    app.state.scheduler.close()
    wait_for(lambda: queued()["status"] == "failed")
    assert not tracker.entered["install"].is_set() and not tracker.entered["render"].is_set()
    tracker.release["analysis"].set()
    wait_for(lambda: active()["status"] == "failed")
    assert render()["status"] == "queued"  # durable narration can resume after restart


def test_uncertain_shutdown_stops_queue_without_spin_and_preserves_existing_retries(scheduled, monkeypatch):
    app, client, tracker, submit = scheduled
    def uncertain_install(cancel_event=None):
        tracker.call("install")
        raise WorkOwnershipUncertain("Explicit fixture ownership uncertainty")
    monkeypatch.setattr(app.state.worker.engines["fixture"], "install", uncertain_install)
    install = submit("install")
    assert tracker.entered["install"].wait(5)
    render = submit("render")
    analysis = submit("analysis")
    tracker.release["install"].set()
    wait_for(lambda: app.state.scheduler.stopped.is_set())
    wait_for(lambda: install()["status"] == analysis()["status"] == "failed")
    assert "restart" in install()["error"]
    app.state.worker.thread.join(1)
    assert not app.state.worker.thread.is_alive()
    assert not tracker.entered["render"].is_set() and not tracker.entered["analysis"].is_set()
    queued = render()
    request = json.loads(app.state.store.item("jobs", queued["id"])["request"])
    assert client.post("/v1/jobs", json=request).json()["id"] == queued["id"]
    request["request_id"] = str(uuid.uuid4())
    rejected = client.post("/v1/jobs", json=request)
    assert rejected.status_code == 503 and "restart" in rejected.text
    rejected = client.post("/v1/admin/engines/fixture/install")
    assert rejected.status_code == 503 and "restart" in rejected.text


def test_setup_cancellation_waits_for_owned_subprocess_exit(tmp_path):
    cancel = threading.Event()
    started = tmp_path / "started"
    output = tmp_path / "forbidden-after-cancel"
    errors = []
    def run():
        try:
            run_setup([sys.executable, "-c", "import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(30); pathlib.Path(sys.argv[2]).touch()", str(started), str(output)], cancel_event=cancel, timeout=40)
        except WorkCancelled: errors.append("cancelled")
    thread = threading.Thread(target=run)
    thread.start()
    wait_for(started.exists)
    cancel.set()
    thread.join(7)
    assert not thread.is_alive() and errors == ["cancelled"] and not output.exists()


def test_setup_tree_cancellation_stops_grandchild_with_inherited_output(tmp_path):
    cancel = threading.Event()
    heartbeat = tmp_path / "grandchild-heartbeat"
    errors = []
    grandchild = "import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); i=0\nwhile True:\n i+=1; p.write_text(str(i)); print(i,flush=True); time.sleep(.02)"
    leader = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]]); time.sleep(30)"
    def run():
        try:
            run_setup([sys.executable, "-c", leader, grandchild, str(heartbeat)], cancel_event=cancel, capture_output=True, timeout=40)
        except WorkCancelled: errors.append("cancelled")
    thread = threading.Thread(target=run)
    thread.start()
    wait_for(lambda: heartbeat.exists() and heartbeat.stat().st_size > 0)
    cancel.set()
    thread.join(7)
    assert not thread.is_alive() and errors == ["cancelled"]
    final = heartbeat.read_bytes()
    time.sleep(.15)
    assert heartbeat.read_bytes() == final


def test_setup_input_and_output_are_preserved_with_containment():
    result = run_setup([sys.executable, "-c", "import sys; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(data); sys.stderr.write('fixture diagnostic')"],
                       input='Original 🧭 fixture.', text=True, capture_output=True, timeout=10)
    assert result.returncode == 0
    assert result.stdout == 'Original 🧭 fixture.' and result.stderr == "fixture diagnostic"


def test_setup_resolves_a_bare_executable_from_supplied_path():
    executable = Path(sys.executable)
    env = {**os.environ, "PATH": str(executable.parent)}
    result = run_setup([executable.name, "-c", "print('resolved fixture command')"], env=env, capture_output=True, text=True, timeout=10)
    assert result.stdout.strip() == "resolved fixture command"
