"""Opt-in whole-book recovery after a real speech request loses its worker.

Only this harness's child process is terminated. An isolated temporary library
contains the original public Lantern EPUB; no personal library is opened. A
transparent loopback observer confirms the second real speech request was sent
upstream and still pending at termination. No fake speech or delay is inserted.
Run with the installed application's Python to check installed code.
"""
import argparse
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit
import uuid
import wave
import zipfile

from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.engines import VoiceStudioEngine
from bookpocket_companion.models import Config
from bookpocket_companion.worker import sentences


class InFlightObserver:
    def __init__(self, origin):
        target = urlsplit(origin)
        if (target.scheme not in {"http", "https"}
                or target.hostname not in {"localhost", "127.0.0.1", "::1"}
                or target.username or target.password or target.query or target.fragment
                or target.path not in {"", "/"}):
            raise ValueError("This smoke requires a local VoiceStudio origin")
        self.inputs = []
        self.dispatched, self.returned = threading.Event(), threading.Event()
        self.error, self.interrupted_audio = None, None
        self.disconnected = False
        observer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass  # Keep voice identifiers and bodies out of logs.

            def do_GET(self):
                self.forward()

            def do_POST(self):
                self.forward()

            def forward(self):
                speech = self.command == "POST" and self.path == "/v1/audio/speech"
                if not (speech or self.command == "GET" and self.path == "/v1/audio/voices"):
                    self.send_error(404)
                    return
                length = int(self.headers.get("Content-Length", 0))
                if not 0 <= length <= 65536:
                    self.send_error(413)
                    return
                body = self.rfile.read(length) if length else None
                interrupted = False
                if speech:
                    observer.inputs.append(json.loads(body)["input"])
                    interrupted = len(observer.inputs) == 2
                connection_type = (http.client.HTTPSConnection if target.scheme == "https"
                                   else http.client.HTTPConnection)
                connection = connection_type(target.hostname, target.port, timeout=240)
                try:
                    connection.request(self.command, self.path, body,
                                       {"Content-Type": "application/json"})
                    if interrupted:
                        observer.dispatched.set()  # Body sent, not merely queued.
                    response = connection.getresponse()
                    content = response.read()
                    if interrupted:
                        if response.status != 200:
                            raise RuntimeError("Real interrupted speech request failed")
                        observer.interrupted_audio = content
                        observer.returned.set()
                    self.send_response(response.status)
                    self.send_header("Content-Type", response.getheader("Content-Type", "application/octet-stream"))
                    self.send_header("Content-Length", str(len(content)))
                    self.end_headers()
                    self.wfile.write(content)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    if interrupted and observer.interrupted_audio:
                        observer.disconnected = True  # Expected for the owned dead child.
                    else:
                        observer.error = "Unexpected client disconnect"
                except Exception:
                    observer.error = "Real upstream forwarding failed"
                finally:
                    connection.close()
                    if interrupted:
                        observer.returned.set()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def checked(response, status=200):
    if response.status_code != status:
        raise RuntimeError(f"Unexpected API status {response.status_code}")
    return response.json()


def configuration(args, root):
    return Config(data_dir=root, dev=True, admin_token=secrets.token_urlsafe(32),
                  voicestudio_url=args.voice_service, ffmpeg=args.ffmpeg)


def child(args):
    root = args.worker_root.resolve()
    if (not root.is_relative_to(Path(tempfile.gettempdir()).resolve())
            or not root.name.startswith("bookpocket-book-inflight-")
            or (root / "isolated-smoke.marker").read_text() != "original Lantern fixture only"):
        raise RuntimeError("Child mode requires this harness's isolated library")
    engine = VoiceStudioEngine(args.voice_service)
    app = create_app(configuration(args, root), engines={engine.id: engine})
    with TestClient(app, client=("127.0.0.1", 1234)):
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            job = json.loads(app.state.store.item("jobs", args.worker_job)["data"])
            if job["status"] == "completed":
                return
            if job["status"] in {"failed", "cancelled"}:
                raise RuntimeError("Recovered job failed")
            time.sleep(.2)
        raise RuntimeError("Whole-book recovery exceeded its bounded timeout")


def stop_owned(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=15)


def spawn(args, root, job_id, log):
    return subprocess.Popen([sys.executable, "-I", str(Path(__file__).resolve()),
        "--voice-service", args.voice_service, "--voice-name", args.voice_name,
        "--ffmpeg", args.ffmpeg, "--ffprobe", args.ffprobe,
        "--report", str(args.report.resolve()), "--worker-root", str(root),
        "--worker-job", job_id], stdout=log, stderr=subprocess.STDOUT,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def run(args):
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="bookpocket-book-inflight-") as directory:
        root = Path(directory).resolve()
        (root / "isolated-smoke.marker").write_text("original Lantern fixture only")
        with InFlightObserver(args.voice_service) as observer:
            args.voice_service = observer.url
            engine = VoiceStudioEngine(observer.url)
            if not engine.info()["available"]:
                raise RuntimeError("The real external OmniVoice engine is unavailable")
            matches = [voice for voice in engine.voices() if voice["name"] == args.voice_name]
            if len(matches) != 1:
                raise RuntimeError("Select one uniquely named external voice")
            config = configuration(args, root)
            app = create_app(config, engines={engine.id: engine}, start_worker=False)
            with TestClient(app, client=("127.0.0.1", 1234)) as api:
                version = checked(api.get("/v1/health"))["version"]
                admin = {"Authorization": "Bearer " + config.admin_token}
                ticket = checked(api.post("/v1/admin/pairing-tickets", headers=admin))
                pending = checked(api.post("/v1/pairings", json={"code": ticket["code"], "device_name": "Isolated book restart smoke"}))
                checked(api.post(f'/v1/admin/pairings/{pending["id"]}/approve', headers=admin))
                approval = checked(api.get(f'/v1/pairings/{pending["id"]}', headers={"Authorization": "Bearer " + pending["poll_token"]}))
                device = {"Authorization": "Bearer " + approval["device_token"]}
                source = (Path(__file__).resolve().parents[1] / "tests/fixtures/lantern.epub").read_bytes()
                book = checked(api.post("/v1/books", headers=device, files={"file": ("lantern.epub", source, "application/epub+zip")}))
                segments = [segment for chapter in book["chapters"] for segment in chapter["segments"]]
                expected = [text for segment in segments for _, _, text in sentences(segment["text"])]
                request = {"request_id": str(uuid.uuid4()), "book_id": book["id"],
                           "segment_ids": [segment["id"] for segment in segments],
                           "engine": engine.id, "voice_id": matches[0]["id"], "announce_chapters": False}
                job_id = checked(api.post("/v1/jobs", json=request, headers=device), 202)["id"]
            process = None
            with (root / "worker.log").open("wb") as log:
                try:
                    process = spawn(args, root, job_id, log)
                    assert observer.dispatched.wait(60), "Second real speech request was not dispatched"
                    assert process.poll() is None and not observer.returned.is_set()
                    interrupted = json.loads(app.state.store.item("jobs", job_id)["data"])
                    assert interrupted["status"] == "running" and interrupted["completed_segments"] == 1
                    first_asset = interrupted["assets"][0]
                    stop_owned(process)
                    assert process.returncode is not None and not observer.returned.is_set(), "Worker did not exit while speech was pending"
                    print("Terminated only the isolated worker during an outstanding real speech response.", flush=True)
                    assert observer.returned.wait(240), "Interrupted upstream request never settled"
                    assert observer.error is None and observer.interrupted_audio
                    with wave.open(io.BytesIO(observer.interrupted_audio)) as wav:
                        discarded_seconds = wav.getnframes() / wav.getframerate()
                        assert discarded_seconds > .01
                    assert len(observer.inputs) == 2
                    process = spawn(args, root, job_id, log)
                    deadline = time.monotonic() + 600
                    while process.poll() is None:
                        if time.monotonic() > deadline:
                            raise RuntimeError("Whole-book recovery exceeded the bounded timeout")
                        time.sleep(.2)
                    if process.returncode != 0:
                        raise RuntimeError(f"Recovered worker exited with code {process.returncode}")
                finally:
                    stop_owned(process)
            rebuilt = create_app(config, engines={engine.id: engine}, start_worker=False)
            with TestClient(rebuilt, client=("127.0.0.1", 1234)) as api:
                job = checked(api.get("/v1/jobs/" + job_id, headers=device))
                assert job["status"] == "completed" and job["completed_segments"] == len(segments)
                assert len(job["assets"]) == len(segments) and job["assets"][0] == first_asset
                assert [asset["segment_id"] for asset in job["assets"]] == request["segment_ids"]
                assert len({asset["id"] for asset in job["assets"]}) == len(segments)
                assert observer.inputs == [*expected[:2], *expected[1:]], "Committed text was resynthesized or source changed"
                assert api.get(f'/v1/books/{book["id"]}/source', headers=device).content == source
                assert checked(api.post("/v1/jobs", json=request, headers=device), 202)["assets"] == job["assets"]
                for segment, asset in zip(segments, job["assets"]):
                    assert (asset["source_start"], asset["source_end"]) == (0, len(segment["text"]))
                    assert all(0 <= timing["start_offset"] < timing["end_offset"] <= len(segment["text"]) for timing in asset["timings"])
                    response = api.get(asset["url"], headers=device)
                    assert response.status_code == 200 and api.get(asset["url"]).status_code == 401
                    assert len(response.content) == asset["bytes"] and hashlib.sha256(response.content).hexdigest() == asset["sha256"]
                    path = root / "checked.wav"
                    path.write_bytes(response.content)
                    subprocess.run([args.ffmpeg, "-v", "error", "-i", str(path), "-f", "null", "-"], check=True, capture_output=True, timeout=120)
                    path.unlink()
                export = checked(api.post(f"/v1/jobs/{job_id}/export", json={"format": "m4b"}, headers=device))
                response = api.get(export["url"], headers=device)
                assert response.status_code == 200 and hashlib.sha256(response.content).hexdigest() == export["sha256"]
                path = root / "book.m4b"
                path.write_bytes(response.content)
                probe = json.loads(subprocess.check_output([args.ffprobe, "-v", "error", "-show_streams", "-show_format", "-show_chapters", "-of", "json", str(path)]))
                assert probe["streams"][0]["codec_name"] == "aac"
                assert [chapter["tags"]["title"] for chapter in probe["chapters"]] == [chapter["title"] for chapter in book["chapters"]]
                assert abs(float(probe["format"]["duration"]) - sum(asset["duration"] for asset in job["assets"])) < .15
                cursor = 0.0
                for actual, chapter in zip(probe["chapters"], book["chapters"]):
                    duration = sum(asset["duration"] for asset in job["assets"] if asset["segment_id"] in {segment["id"] for segment in chapter["segments"]})
                    assert abs(float(actual["start_time"]) - cursor) < .15
                    cursor += duration
                    assert abs(float(actual["end_time"]) - cursor) < .15
                subprocess.run([args.ffmpeg, "-v", "error", "-i", str(path), "-f", "null", "-"], check=True, capture_output=True, timeout=120)
                portable = checked(api.post(f"/v1/jobs/{job_id}/export", json={"format": "project"}, headers=device))
                content = api.get(portable["url"], headers=device).content
                assert hashlib.sha256(content).hexdigest() == portable["sha256"]
                with zipfile.ZipFile(io.BytesIO(content)) as archive:
                    assert archive.testzip() is None and archive.read("source.epub") == source
                    assert not any(name.startswith("voices/") for name in archive.namelist())
                    for asset in job["assets"]:
                        assert hashlib.sha256(archive.read("audio/" + asset["id"] + ".wav")).hexdigest() == asset["sha256"]
                with rebuilt.state.store.db() as db:
                    persisted = [json.loads(row["data"]) for row in db.execute("SELECT data FROM assets")]
                    passages = [asset for asset in persisted if asset.get("segment_id")]
                    assert {asset["id"] for asset in passages} == {asset["id"] for asset in job["assets"]}
                    assert len(passages) == len(segments)
                    assert db.execute("SELECT COUNT(*) FROM devices").fetchone()[0] == 1
                temporary_dirs = [path.name for path in (root / "assets").iterdir() if path.is_dir()]
                result = {"companion_version": version, "engine": "real external OmniVoice",
                          "scope": "complete original two-chapter Lantern fixture",
                          "process_exit_while_real_response_pending": "pass",
                          "automatic_recovery_and_committed_asset_preserved": "pass",
                          "exact_original_inputs_and_nonduplicated_assets": "pass",
                          "authenticated_downloads_and_full_decode": "pass",
                          "source_pairing_portable_project_preserved": "pass",
                          "m4b_contiguous_chapters": "pass", "assets": len(job["assets"]),
                          "synthesis_calls": len(observer.inputs), "discarded_upstream_seconds": discarded_seconds,
                          "audio_seconds": sum(asset["duration"] for asset in job["assets"]),
                          "m4b_sha256": export["sha256"], "orphaned_temporary_directories": len(temporary_dirs),
                          "scratch_cleanup": "pass" if not temporary_dirs else "fail",
                          "wall_seconds": round(time.monotonic() - started, 3),
                          "novel_endurance_or_power_cycle": "NOT RUN", "physical_iphone_flow": "NOT RUN"}
                args.report.parent.mkdir(parents=True, exist_ok=True)
                args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
                print(json.dumps(result, indent=2))
                assert not temporary_dirs, "Recovered book left abandoned render workspaces"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--voice-service", required=True)
    parser.add_argument("--voice-name", required=True)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--worker-root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--worker-job", help=argparse.SUPPRESS)
    args = parser.parse_args()
    child(args) if args.worker_root else run(args)
