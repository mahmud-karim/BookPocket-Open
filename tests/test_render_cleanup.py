"""Crash cleanup outcomes using explicit test tones, never a real-TTS claim."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion.store import Store, canonical
from test_source_ranges import SelectionEngine


def api(app):
    return TestClient(app, client=("127.0.0.1", 4321),
                      headers={"Authorization": "Bearer cleanup-test-only"})


def test_real_worker_process_exit_cleans_interrupted_workspace_and_recovers_job(tmp_path):
    root = tmp_path / "library"
    config = Config(data_dir=root, admin_token="cleanup-test-only", dev=True)
    source = "First durable original sentence.\n\nSecond interrupted original sentence."
    original = create_app(config, engines={SelectionEngine.id: SelectionEngine()}, start_worker=False)
    with api(original) as client:
        imported = client.post("/v1/books", files={"file": ("original.txt", source.encode())})
        assert imported.status_code == 200, imported.text
        book = imported.json()
        request = {"request_id": str(uuid.uuid4()), "book_id": book["id"],
                   "segment_ids": [s["id"] for s in book["chapters"][0]["segments"]],
                   "engine": SelectionEngine.id, "voice_id": "selection-test:voice"}
        queued = client.post("/v1/jobs", json=request)
        assert queued.status_code == 202, queued.text
        job_id = queued.json()["id"]

    # Exit in synthesis after the next raw file is written: no exception cleanup,
    # lifespan exit, or Python finally block can remove that render workspace.
    child = r'''
import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from test_source_ranges import SelectionEngine
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
class InterruptedEngine(SelectionEngine):
    def synthesize(self, text, voice, output, language):
        result = super().synthesize(text, voice, output, language)
        if len(self.calls) == 2: os._exit(77)
        return result
engine = InterruptedEngine()
app = create_app(Config(data_dir=Path(sys.argv[2]), admin_token="cleanup-test-only", dev=True), engines={engine.id: engine}, start_worker=False)
app.state.worker.run(sys.argv[3])
raise SystemExit("Worker did not reach the intended crash boundary")
'''
    result = subprocess.run([sys.executable, "-c", child, str(Path(__file__).parent), str(root), job_id],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 77, result.stderr
    crashed = json.loads(original.state.store.item("jobs", job_id)["data"])
    assert crashed["status"] == "running"
    assert crashed["completed_segments"] == 1
    first = crashed["assets"][0]
    first_path = Path(original.state.store.item("assets", first["id"])["path"])
    first_bytes = first_path.read_bytes()
    abandoned = [p for p in (root / "assets").iterdir() if p.is_dir()]
    assert len(abandoned) == 1, "The crash must actually leave one interrupted workspace"
    assert any(p.suffix == ".wav" for p in abandoned[0].iterdir())

    # Unknown files and old unmarked temporary directories must survive startup.
    legacy = root / "assets" / "tmp-legacy-unmarked"
    legacy.mkdir()
    legacy_file = legacy / "0-raw.wav"
    legacy_file.write_bytes(b"legacy file that this version does not own")
    unknown = root / "assets" / "user-notes.txt"
    unknown.write_bytes(b"retain")
    resumed_engine = SelectionEngine()
    resumed = create_app(config, engines={resumed_engine.id: resumed_engine}, start_worker=True)
    with api(resumed) as client:
        deadline = time.monotonic() + 15
        while True:
            finished = client.get("/v1/jobs/" + job_id).json()
            if finished["status"] in {"completed", "failed"} or time.monotonic() >= deadline:
                break
            time.sleep(.02)
        assert finished["status"] == "completed", finished
        assert finished["completed_segments"] == finished["total_segments"] == 2
        assert len({a["segment_id"] for a in finished["assets"]}) == 2
        assert finished["assets"][0]["id"] == first["id"]
        assert resumed_engine.calls == ["Second interrupted original sentence."]
        assert first_path.read_bytes() == first_bytes
        assert hashlib.sha256(first_bytes).hexdigest() == first["sha256"]
        assert not abandoned[0].exists()
        assert legacy_file.read_bytes() == b"legacy file that this version does not own"
        assert unknown.read_bytes() == b"retain"
        assert client.get(f'/v1/books/{book["id"]}/source').content == source.encode()


def abandoned_workspace(tmp_path):
    """Leave a genuine registered workspace by exiting without context teardown."""
    root = tmp_path / "library"
    child = r'''
import os, sys
from pathlib import Path
from bookpocket_companion.store import Store
from bookpocket_companion.render_workspace import render_workspace
store = Store(Path(sys.argv[1]))
with render_workspace(store, "interrupted-job", "interrupted-segment") as work:
    (work / "0-raw.wav").write_bytes(b"unfinished test-only wave bytes")
    (work / "joined.wav").write_bytes(b"unfinished joined test audio")
    print(work.name, flush=True)
    os._exit(77)
'''
    result = subprocess.run([sys.executable, "-c", child, str(root)], capture_output=True, text=True, timeout=15)
    assert result.returncode == 77, result.stderr
    work = root / "assets" / result.stdout.strip()
    assert work.is_dir() and work.parent == root / "assets"
    return Store(root), work


def directory_link(link, target):
    if os.name == "nt":
        # Junctions exercise Windows reparse-point safety without symlink privilege.
        result = subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(link), str(target)], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert link.is_dir()
    else:
        link.symlink_to(target, target_is_directory=True)


def relocate_test_directory(path, destination, tmp_path):
    # All directory moves are constrained to this test's fresh isolated workspace.
    assert path.resolve().is_relative_to(tmp_path.resolve())
    assert destination.resolve().is_relative_to(tmp_path.resolve())
    path.rename(destination)


def test_abandoned_workspace_cleanup_is_idempotent_and_retains_durable_index(tmp_path):
    from bookpocket_companion.render_workspace import cleanup_abandoned_renders
    store, work = abandoned_workspace(tmp_path)
    durable = store.root / "assets" / "durable.wav"
    content = (Path(__file__).parent / "fixtures/test-tone.wav").read_bytes()
    durable.write_bytes(content)
    # A lookalike name/marker is insufficient without the durable registry entry.
    unregistered = store.root / "assets" / ("bookpocket-render-" + str(uuid.uuid4()))
    unregistered.mkdir()
    (unregistered / ".bookpocket-render.json").write_bytes((work / ".bookpocket-render.json").read_bytes())
    (unregistered / "0-raw.wav").write_bytes(b"unregistered scratch must be preserved")
    with store.db() as db:
        db.execute("INSERT INTO assets VALUES(?,?,?,?)", ("durable", "cache", canonical({"id": "durable"}), str(durable)))
    assert cleanup_abandoned_renders(store) == 1
    assert cleanup_abandoned_renders(store) == 0
    assert not work.exists()
    assert durable.read_bytes() == content
    assert store.item("assets", "durable")["cache_key"] == "cache"
    assert (unregistered / "0-raw.wav").read_bytes() == b"unregistered scratch must be preserved"


@pytest.mark.parametrize("protection", ["unknown-file", "indexed-audio", "invalid-marker"])
def test_uncertain_workspace_is_preserved_in_full(tmp_path, protection):
    from bookpocket_companion.render_workspace import cleanup_abandoned_renders
    store, work = abandoned_workspace(tmp_path)
    if protection == "unknown-file":
        (work / "user-recording.wav").write_bytes(b"not owned by render cleanup")
    elif protection == "indexed-audio":
        with store.db() as db:
            db.execute("INSERT INTO assets VALUES(?,?,?,?)", ("indexed", "cache", canonical({"id": "indexed"}), str(work / "0-raw.wav")))
    else:
        (work / ".bookpocket-render.json").write_text('{"unrecognized":"marker"}')
    before = {p.name: p.read_bytes() for p in work.iterdir()}
    cleanup_abandoned_renders(store)
    assert {p.name: p.read_bytes() for p in work.iterdir()} == before


@pytest.mark.parametrize("placement", ["workspace", "assets-root", "nested-entry"])
def test_cleanup_never_follows_links_outside_assets(tmp_path, placement):
    from bookpocket_companion.render_workspace import cleanup_abandoned_renders
    store, work = abandoned_workspace(tmp_path)
    outside = tmp_path / "outside-assets"
    if placement == "workspace":
        relocate_test_directory(work, outside, tmp_path)
        directory_link(work, outside)
        target = outside
    elif placement == "assets-root":
        relocate_test_directory(store.root / "assets", outside, tmp_path)
        directory_link(store.root / "assets", outside)
        target = outside / work.name
    else:
        outside.mkdir()
        (outside / "personal.wav").write_bytes(b"must never be traversed or removed")
        # Use a recognized render-file name so preservation requires link/type checks.
        directory_link(work / "7-raw.wav", outside)
        target = work
    target_before = {p.name: p.read_bytes() for p in target.iterdir() if p.is_file()}
    # A recognized filename avoids unknown-entry protection masking link bugs.
    sentinel = outside / "9-raw.wav"
    sentinel.write_bytes(b"outside data remains intact")
    assert cleanup_abandoned_renders(store) == 0
    assert sentinel.read_bytes() == b"outside data remains intact"
    for name, content in target_before.items():
        assert (target / name).read_bytes() == content
    if placement == "nested-entry":
        assert (outside / "personal.wav").read_bytes() == b"must never be traversed or removed"


def test_active_workspace_lease_prevents_startup_cleanup(tmp_path):
    from bookpocket_companion.render_workspace import cleanup_abandoned_renders, render_workspace
    store = Store(tmp_path / "library")
    with render_workspace(store, "active-job", "active-segment") as work:
        (work / "0-raw.wav").write_bytes(b"active synthesis data")
        assert cleanup_abandoned_renders(store) == 0
        assert (work / "0-raw.wav").read_bytes() == b"active synthesis data"
    assert not work.exists()
