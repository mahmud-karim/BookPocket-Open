"""Opt-in real external narration cancellation during an outstanding HTTP request.

Uses original test words and fresh temporary stores with an approved test device.
A transparent loopback observer marks actual upstream request dispatch; no fake
speech or artificial synthesis delay is used. The external model may finish its
request, but the cancelled companion job must publish no audio. Run with the
packaged Python runtime to check installed application code.
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
import tempfile
import threading
import time
from urllib.parse import urlsplit
import uuid
import wave

from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.engines import VoiceStudioEngine
from bookpocket_companion.models import Config


class ObservedService:
    """Forward real speech/inventory requests without retaining private IDs."""
    def __init__(self, service, root):
        target = urlsplit(service)
        if (target.scheme not in {"http", "https"}
                or target.hostname not in {"localhost", "127.0.0.1", "::1"}
                or target.username or target.password or target.query or target.fragment
                or target.path not in {"", "/"}):
            raise ValueError("This smoke requires a local VoiceStudio origin")
        self.root, self.inputs = root, []
        self.dispatched, self.returned = threading.Event(), threading.Event()
        self.error, self.first_audio = None, None
        observer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass  # Never log voice identifiers or request bodies.

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
                first = False
                if speech:
                    payload = json.loads(body)
                    first = not observer.inputs
                    observer.inputs.append(payload["input"])
                connection_type = (http.client.HTTPSConnection if target.scheme == "https"
                                   else http.client.HTTPConnection)
                connection = connection_type(target.hostname, target.port, timeout=240)
                try:
                    # request() returns only after the body is sent upstream.
                    connection.request(self.command, self.path, body,
                                       {"Content-Type": "application/json"})
                    if first:
                        observer.dispatched.set()
                    response = connection.getresponse()
                    content = response.read()
                    if first:
                        if response.status != 200:
                            raise RuntimeError("The real speech request failed")
                        observer.first_audio = content
                        observer.returned.set()
                    self.send_response(response.status)
                    self.send_header("Content-Type", response.getheader("Content-Type", "application/octet-stream"))
                    self.send_header("Content-Length", str(len(content)))
                    self.end_headers()
                    self.wfile.write(content)
                except Exception:
                    observer.error = "The isolated forwarding request failed"
                    if first:
                        observer.returned.set()
                    self.send_error(502)
                finally:
                    connection.close()

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
        raise RuntimeError(f"API returned unexpected status {response.status_code}")
    return response.json()


def pair(api, config):
    admin = {"Authorization": "Bearer " + config.admin_token}
    ticket = checked(api.post("/v1/admin/pairing-tickets", headers=admin))
    pending = checked(api.post("/v1/pairings", json={
        "code": ticket["code"], "device_name": "Isolated cancellation smoke"}))
    checked(api.post(f'/v1/admin/pairings/{pending["id"]}/approve', headers=admin))
    approval = checked(api.get(f'/v1/pairings/{pending["id"]}', headers={
        "Authorization": "Bearer " + pending["poll_token"]}))
    return {"Authorization": "Bearer " + approval["device_token"]}


def decode(content, path, ffmpeg):
    with wave.open(io.BytesIO(content)) as wav:
        assert wav.getnchannels() == 1 and wav.getframerate() == 24000
        assert wav.getsampwidth() == 2 and wav.getnframes() > 240
        duration = wav.getnframes() / wav.getframerate()
    path.write_bytes(content)
    subprocess.run([ffmpeg, "-v", "error", "-i", str(path), "-f", "null", "-"],
                   check=True, capture_output=True, timeout=120)
    path.unlink()
    return {"duration": duration, "sha256": hashlib.sha256(content).hexdigest()}


def run(args):
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="bookpocket-reader-cancel-") as directory:
        root = Path(directory)
        with ObservedService(args.voice_service, root) as observer:
            engine = VoiceStudioEngine(observer.url)
            if not engine.info()["available"]:
                raise RuntimeError("The real external OmniVoice engine is unavailable")
            voices = [voice for voice in engine.voices() if voice["name"] == args.voice_name]
            if len(voices) != 1:
                raise RuntimeError("Select one uniquely named real external voice")
            config = Config(data_dir=root / "library", dev=True,
                            admin_token=secrets.token_urlsafe(32),
                            voicestudio_url=observer.url, ffmpeg=args.ffmpeg)
            app = create_app(config, engines={engine.id: engine}, start_worker=False)
            with TestClient(app, client=("127.0.0.1", 1234)) as api:
                version = checked(api.get("/v1/health"))["version"]
                device = pair(api, config)
                excerpts = [
                    "Mira raised the lantern and watched its warm light cross the table while the compass rested beside the open window.",
                    "Outside, the quiet town waited for sunrise.",
                ]
                paragraphs = ["Before this page. " + excerpts[0] + " After this page.",
                              "Beyond the window. " + excerpts[1] + " Another chapter follows."]
                source = "\n\n".join(paragraphs).encode()
                book = checked(api.post("/v1/books", headers=device, files={
                    "file": ("original-cancellation-smoke.txt", source, "text/plain")}))
                segments = book["chapters"][0]["segments"]
                ranges = [{"segment_id": segment["id"],
                           "start_offset": segment["text"].index(excerpt),
                           "end_offset": segment["text"].index(excerpt) + len(excerpt)}
                          for segment, excerpt in zip(segments, excerpts)]
                request = {"request_id": str(uuid.uuid4()), "book_id": book["id"],
                           "segment_ids": [segment["id"] for segment in segments],
                           "source_ranges": ranges, "engine": engine.id,
                           "voice_id": voices[0]["id"], "language": "en"}
                job_id = checked(api.post("/v1/jobs", json=request, headers=device), 202)["id"]
                # Use the unchanged production Worker.run in an owned thread so
                # joining it proves all late normalization/publication is over.
                worker = threading.Thread(target=app.state.worker.run, args=(job_id,), daemon=True)
                worker.start()
                try:
                    assert observer.dispatched.wait(30), "No actual speech request was dispatched"
                    assert not observer.returned.is_set(), "Speech already finished before cancellation"
                    running = checked(api.get("/v1/jobs/" + job_id, headers=device))
                    assert running["status"] == "running" and running["completed_segments"] == 0
                    cancelled = checked(api.post(f"/v1/jobs/{job_id}/cancel", headers=device))
                    assert cancelled["status"] == "cancelled"
                    assert not observer.returned.is_set(), "Cancel returned after the speech request had finished"
                    print("Cancelled the isolated job while its real upstream speech response was pending.", flush=True)
                finally:
                    worker.join(timeout=370)
                assert not worker.is_alive(), "Cancelled worker did not finish within the bounded timeout"
                assert observer.error is None and observer.first_audio
                discarded_audio = decode(observer.first_audio, root / "discarded.wav", args.ffmpeg)
                finished = checked(api.get("/v1/jobs/" + job_id, headers=device))
                assert finished["status"] == "cancelled" and finished["assets"] == []
                assert finished["completed_segments"] == 0 and finished["source_ranges"] == ranges
                assert observer.inputs == excerpts[:1], "Cancellation dispatched additional text"
                assert api.post(f"/v1/jobs/{job_id}/export", json={"format": "m4b"}, headers=device).status_code == 409
                assert checked(api.post("/v1/jobs", json=request, headers=device), 202)["id"] == job_id
                with app.state.store.db() as db:
                    assert db.execute("SELECT COUNT(*) FROM assets").fetchone()[0] == 0
                assert list((config.data_dir / "assets").iterdir()) == [], "Cancelled render leaked audio or temporary files"

            # A fresh API/worker must retain cancellation and the paired identity.
            rebuilt = create_app(config, engines={engine.id: engine})
            with TestClient(rebuilt, client=("127.0.0.1", 1234)) as api:
                assert checked(api.get("/v1/jobs/" + job_id, headers=device))["status"] == "cancelled"
                checked(api.post(f"/v1/jobs/{job_id}/retry", headers=device))
                deadline = time.monotonic() + 240
                while True:
                    job = checked(api.get("/v1/jobs/" + job_id, headers=device))
                    if job["status"] == "completed":
                        break
                    if job["status"] in {"failed", "cancelled"} or time.monotonic() > deadline:
                        raise RuntimeError("Real retry failed or exceeded the bounded timeout")
                    time.sleep(.2)
                assert job["completed_segments"] == 2 and len(job["assets"]) == 2
                assert job["source_ranges"] == ranges
                assert observer.inputs == [excerpts[0], *excerpts]
                assert api.get(f'/v1/books/{book["id"]}/source', headers=device).content == source
                assert [asset["segment_id"] for asset in job["assets"]] == request["segment_ids"]
                assert len({asset["id"] for asset in job["assets"]}) == 2
                audio = []
                for asset, selected in zip(job["assets"], ranges):
                    assert (asset["source_start"], asset["source_end"]) == (selected["start_offset"], selected["end_offset"])
                    assert all(selected["start_offset"] <= timing["start_offset"] < timing["end_offset"] <= selected["end_offset"] for timing in asset["timings"])
                    response = api.get(asset["url"], headers=device)
                    assert response.status_code == 200 and api.get(asset["url"]).status_code == 401
                    assert len(response.content) == asset["bytes"]
                    assert hashlib.sha256(response.content).hexdigest() == asset["sha256"]
                    metadata = decode(response.content, root / "checked.wav", args.ffmpeg)
                    assert metadata["duration"] == asset["duration"]
                    audio.append(metadata)
                with rebuilt.state.store.db() as db:
                    assert db.execute("SELECT COUNT(*) FROM assets").fetchone()[0] == 2
                    assert db.execute("SELECT COUNT(*) FROM devices").fetchone()[0] == 1
                assert len(list((config.data_dir / "assets").iterdir())) == 2
            result = {"companion_version": version, "voice_name": args.voice_name,
                      "engine": "real external OmniVoice", "actual_network_dispatch_before_cancel": "pass",
                      "upstream_response_pending_after_cancel": "pass", "cancelled_audio_not_published": "pass",
                      "no_late_assets_or_temporary_files": "pass", "cancelled_state_survives_reopen": "pass",
                      "retry_exact_original_ranges": "pass", "authenticated_download_and_decode": "pass",
                      "source_and_pairing_preserved": "pass", "discarded_upstream_audio": discarded_audio,
                      "retry_audio": audio, "synthesis_calls": len(observer.inputs),
                      "wall_seconds": round(time.monotonic() - started, 3),
                      "external_model_compute_abort": "NOT CLAIMED", "physical_iphone_flow": "NOT RUN"}
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--voice-service", required=True)
    parser.add_argument("--voice-name", required=True)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--report", type=Path, required=True)
    run(parser.parse_args())
