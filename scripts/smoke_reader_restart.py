"""Opt-in real external narration recovery across an abrupt worker-process exit.

Uses only original fixture words in a new temporary library. The first worker is
held before its second synthesis call, after the first asset has been committed.
Only this harness's child process is terminated; the installed companion stays up.
Run with the packaged Python runtime to verify the installed application code.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import uuid
import wave

from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.engines import VoiceStudioEngine
from bookpocket_companion.models import Config


class ObservedEngine:
    def __init__(self, url, root, hold_second=False):
        self.engine = VoiceStudioEngine(url)
        self.id, self.version = self.engine.id, self.engine.version
        self.root, self.hold_second, self.calls = root, hold_second, 0

    def info(self): return self.engine.info()
    def voices(self): return self.engine.voices()

    def synthesize(self, text, voice, output, language="en"):
        self.calls += 1
        if self.hold_second and self.calls == 2:
            (self.root / "boundary.ready").write_text("first asset committed", encoding="utf-8")
            # Parent terminates this child at the durable passage boundary.
            while True:
                time.sleep(.1)
        with (self.root / "observed-inputs.jsonl").open("a", encoding="utf-8") as log:
            log.write(json.dumps(text, ensure_ascii=False) + "\n")
        return self.engine.synthesize(text, voice, output, language)


def checked(response, status=200):
    if response.status_code != status:
        raise RuntimeError(f"API returned {response.status_code}: {response.text}")
    return response.json()


def configuration(args, root):
    return Config(data_dir=root, dev=True, admin_token=secrets.token_urlsafe(32),
                  voicestudio_url=args.voice_service, ffmpeg=args.ffmpeg)


def child(args):
    root = args.worker_root.resolve()
    # Internal child mode must never accidentally run against a personal library.
    if (not root.is_relative_to(Path(tempfile.gettempdir()).resolve())
            or not root.name.startswith("bookpocket-reader-restart-")
            or (root / "isolated-smoke.marker").read_text() != "original test text only"):
        raise RuntimeError("Worker mode requires this harness's isolated temporary library")
    engine = ObservedEngine(args.voice_service, root, args.hold_second)
    app = create_app(configuration(args, root), engines={engine.id: engine})
    with TestClient(app, client=("127.0.0.1", 1234)):
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            job = json.loads(app.state.store.item("jobs", args.worker_job)["data"])
            if job["status"] == "completed":
                return
            if job["status"] in {"failed", "cancelled"}:
                raise RuntimeError("Recovery generation failed: " + str(job.get("error") or job["status"]))
            time.sleep(.2)
        raise RuntimeError("Real narration exceeded the bounded smoke timeout")


def spawn(args, root, job_id, log, hold=False):
    command = [sys.executable, "-I", str(Path(__file__).resolve()),
               "--voice-service", args.voice_service, "--voice-name", args.voice_name,
               "--ffmpeg", args.ffmpeg, "--report", str(args.report.resolve()),
               "--worker-root", str(root), "--worker-job", job_id]
    if hold:
        command.append("--hold-second")
    return subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def stop_owned(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=15)


def run(args):
    started = time.monotonic()
    service = VoiceStudioEngine(args.voice_service)
    if not service.info()["available"]:
        raise RuntimeError("The external OmniVoice service is unavailable")
    matches = [v for v in service.voices() if v["name"] == args.voice_name]
    if len(matches) != 1:
        raise RuntimeError("Select one uniquely named external voice profile")
    with tempfile.TemporaryDirectory(prefix="bookpocket-reader-restart-") as directory:
        root = Path(directory).resolve()
        (root / "isolated-smoke.marker").write_text("original test text only")
        config = configuration(args, root)
        app = create_app(config, engines={service.id: service}, start_worker=False)
        with TestClient(app, client=("127.0.0.1", 1234)) as api:
            health = checked(api.get("/v1/health"))
            assert "source_ranges" in health.get("capabilities", [])
            admin = {"Authorization": "Bearer " + config.admin_token}
            ticket = checked(api.post("/v1/admin/pairing-tickets", headers=admin))
            pending = checked(api.post("/v1/pairings", json={"code": ticket["code"], "device_name": "Isolated restart smoke"}))
            checked(api.post(f'/v1/admin/pairings/{pending["id"]}/approve', headers=admin))
            approval = checked(api.get(f'/v1/pairings/{pending["id"]}', headers={"Authorization": "Bearer " + pending["poll_token"]}))
            device = {"Authorization": "Bearer " + approval["device_token"]}
            source = ("Before this page, the lantern was unlit. Mira raised the lantern and watched its warm light cross the table. Beyond this page, the compass pointed north.\n\n"
                      "A compass 🧭 rested beside the window. Outside, the quiet town waited for sunrise. After this page, the bell would ring.").encode()
            book = checked(api.post("/v1/books", files={"file": ("original-restart-smoke.txt", source, "text/plain")}, headers=device))
            segments = book["chapters"][0]["segments"]
            excerpts = ["Mira raised the lantern and watched its warm light", "A compass 🧭 rested beside the window."]
            ranges = [{"segment_id": s["id"], "start_offset": s["text"].index(text),
                       "end_offset": s["text"].index(text) + len(text)} for s, text in zip(segments, excerpts)]
            request = {"request_id": str(uuid.uuid4()), "book_id": book["id"],
                       "segment_ids": [s["id"] for s in segments], "source_ranges": ranges,
                       "engine": service.id, "voice_id": matches[0]["id"]}
            job_id = checked(api.post("/v1/jobs", json=request, headers=device), 202)["id"]

        process = None
        with (root / "worker.log").open("wb") as log:
            try:
                process = spawn(args, root, job_id, log, hold=True)
                deadline = time.monotonic() + 240
                while not (root / "boundary.ready").exists():
                    if process.poll() is not None:
                        raise RuntimeError("First isolated worker exited before its committed passage")
                    if time.monotonic() > deadline:
                        raise RuntimeError("No durable passage appeared within the smoke timeout")
                    time.sleep(.1)
                interrupted = json.loads(app.state.store.item("jobs", job_id)["data"])
                assert interrupted["status"] == "running" and interrupted["completed_segments"] == 1
                assert len(interrupted["assets"]) == 1
                first_asset = interrupted["assets"][0]
                stop_owned(process)
                assert process.returncode is not None
                print("Terminated the isolated worker after its first committed real passage.", flush=True)
                process = spawn(args, root, job_id, log)
                deadline = time.monotonic() + 240
                while process.poll() is None:
                    if time.monotonic() > deadline:
                        raise RuntimeError("Recovered worker exceeded the smoke timeout")
                    time.sleep(.2)
                if process.returncode != 0:
                    raise RuntimeError(f"Recovered worker exited with code {process.returncode}")
            finally:
                stop_owned(process)

        # Read through a fresh API and the original paired-device identity.
        rebuilt = create_app(config, engines={service.id: service}, start_worker=False)
        with TestClient(rebuilt, client=("127.0.0.1", 1234)) as api:
            finished = checked(api.get("/v1/jobs/" + job_id, headers=device))
            assert finished["status"] == "completed" and finished["completed_segments"] == 2
            assert finished["source_ranges"] == ranges and len(finished["assets"]) == 2
            assert finished["assets"][0] == first_asset
            assert len({a["segment_id"] for a in finished["assets"]}) == 2
            observed = [json.loads(line) for line in (root / "observed-inputs.jsonl").read_text(encoding="utf-8").splitlines()]
            assert observed == excerpts, "Completed text was regenerated or selection changed"
            assert checked(api.post("/v1/jobs", json=request, headers=device), 202)["id"] == job_id
            assert api.get(f'/v1/books/{book["id"]}/source', headers=device).content == source
            audio = []
            for asset, selected in zip(finished["assets"], ranges):
                assert (asset["source_start"], asset["source_end"]) == (selected["start_offset"], selected["end_offset"])
                assert all(selected["start_offset"] <= t["start_offset"] < t["end_offset"] <= selected["end_offset"] for t in asset["timings"])
                response = api.get(asset["url"], headers=device)
                assert response.status_code == 200 and hashlib.sha256(response.content).hexdigest() == asset["sha256"]
                assert api.get(asset["url"]).status_code == 401
                with wave.open(io.BytesIO(response.content)) as wav:
                    assert wav.getnchannels() == 1 and wav.getframerate() == 24000
                    assert wav.getnframes() / wav.getframerate() == asset["duration"]
                file = root / (asset["id"] + ".wav")
                file.write_bytes(response.content)
                subprocess.run([args.ffmpeg, "-v", "error", "-i", str(file), "-f", "null", "-"], check=True, capture_output=True, timeout=120)
                audio.append({"duration": asset["duration"], "sha256": asset["sha256"]})
            with rebuilt.state.store.db() as db:
                assert db.execute("SELECT COUNT(*) FROM assets").fetchone()[0] == 2
                assert db.execute("SELECT COUNT(*) FROM devices").fetchone()[0] == 1
        result = {"companion_version": health["version"], "voice_name": args.voice_name,
                  "engine": "real external OmniVoice", "abrupt_process_exit_at_asset_boundary": "pass",
                  "automatic_restart_recovery": "pass", "completed_asset_preserved": "pass",
                  "exact_inputs_without_resynthesis": "pass", "source_and_pairing_preserved": "pass",
                  "authenticated_download_and_decode": "pass", "audio": audio,
                  "wall_seconds": round(time.monotonic() - started, 3),
                  "physical_iphone_flow": "NOT RUN", "power_cycle_or_inflight_service_failure": "NOT RUN"}
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--voice-service", required=True)
    parser.add_argument("--voice-name", required=True)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--worker-root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--worker-job", help=argparse.SUPPRESS)
    parser.add_argument("--hold-second", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    child(args) if args.worker_root else run(args)
