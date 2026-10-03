"""Opt-in packaged-runtime smoke using a real external voice and original test text.

Creates an isolated library and exercises approved device pairing, exact-source
generation, authenticated download and cache reuse. Never opens the user's library.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import uuid
import wave

from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.engines import VoiceStudioEngine
from bookpocket_companion.models import Config


class ObservedExternalEngine:
    """Record inputs while delegating every synthesis call to the real adapter."""
    def __init__(self, url):
        self.engine = VoiceStudioEngine(url)
        self.id, self.version = self.engine.id, self.engine.version
        self.inputs = []

    def info(self): return self.engine.info()
    def voices(self): return self.engine.voices()

    def synthesize(self, text, voice, output, language="en"):
        self.inputs.append(text)
        return self.engine.synthesize(text, voice, output, language)


def checked(response, status=200):
    if response.status_code != status:
        raise RuntimeError(f"API returned {response.status_code}: {response.text}")
    return response.json()


def run(args):
    engine = ObservedExternalEngine(args.voice_service)
    if not engine.info()["available"]:
        raise RuntimeError("The external OmniVoice service is unavailable")
    matches = [voice for voice in engine.voices() if voice["name"] == args.voice_name]
    if len(matches) != 1:
        raise RuntimeError("Select one uniquely named external voice profile")
    voice = matches[0]
    with tempfile.TemporaryDirectory(prefix="bookpocket-real-reader-smoke-") as directory:
        root = Path(directory)
        config = Config(data_dir=root, dev=True, admin_token=secrets.token_urlsafe(32),
                        voicestudio_url=args.voice_service, ffmpeg=args.ffmpeg)
        app = create_app(config, engines={engine.id: engine})
        with TestClient(app, base_url="http://localhost:8783", client=("127.0.0.1", 1234)) as client:
            health = checked(client.get("/v1/health"))
            assert "source_ranges" in health.get("capabilities", [])
            admin = {"Authorization": "Bearer " + config.admin_token}
            ticket = checked(client.post("/v1/admin/pairing-tickets", headers=admin))
            pending = checked(client.post("/v1/pairings", json={"code": ticket["code"], "device_name": "Isolated reader smoke"}))
            checked(client.post("/v1/admin/pairings/" + pending["id"] + "/approve", headers=admin))
            approved = checked(client.get("/v1/pairings/" + pending["id"], headers={"Authorization": "Bearer " + pending["poll_token"]}))
            device = {"Authorization": "Bearer " + approved["device_token"]}
            paragraphs = [
                "Before this page, the lantern was unlit. Mira raised the lantern and watched its warm light cross the table. Beyond this page, the compass pointed north.",
                "A compass 🧭 rested beside the window. Outside, the quiet town waited for sunrise. After this page, the bell would ring.",
            ]
            book = checked(client.post("/v1/books", files={"file": ("original-reader-smoke.txt", "\n\n".join(paragraphs).encode(), "text/plain")}, headers=device))
            segments = book["chapters"][0]["segments"]
            excerpts = ["Mira raised the lantern and watched its warm light", "A compass 🧭 rested beside the window."]
            ranges = [{"segment_id": segment["id"], "start_offset": segment["text"].index(excerpt),
                       "end_offset": segment["text"].index(excerpt) + len(excerpt)}
                      for segment, excerpt in zip(segments, excerpts)]
            request = {"request_id": str(uuid.uuid4()), "book_id": book["id"],
                       "segment_ids": [segment["id"] for segment in segments], "source_ranges": ranges,
                       "engine": engine.id, "voice_id": voice["id"], "language": "en",
                       "announce_chapters": False}

            def generate(body):
                job = checked(client.post("/v1/jobs", json=body, headers=device), 202)
                deadline = time.monotonic() + 240
                while job["status"] not in {"completed", "failed", "cancelled"} and time.monotonic() < deadline:
                    time.sleep(.25)
                    job = checked(client.get("/v1/jobs/" + job["id"], headers=device))
                if job["status"] != "completed":
                    raise RuntimeError("Real generation did not complete: " + str(job.get("error") or job["status"]))
                return job

            job = generate(request)
            assert engine.inputs == excerpts, "Generation expanded or altered the requested original text"
            assert job["source_ranges"] == ranges
            audio = []
            for asset, selected in zip(job["assets"], ranges):
                assert asset["source_start"] == selected["start_offset"]
                assert asset["source_end"] == selected["end_offset"]
                assert all(selected["start_offset"] <= timing["start_offset"] < timing["end_offset"] <= selected["end_offset"] for timing in asset["timings"])
                response = client.get(asset["url"], headers=device)
                assert response.status_code == 200
                assert hashlib.sha256(response.content).hexdigest() == asset["sha256"]
                assert client.get(asset["url"]).status_code == 401
                with wave.open(io.BytesIO(response.content)) as wav:
                    assert wav.getnchannels() == 1 and wav.getframerate() == 24000 and wav.getnframes() > 240
                file = root / (asset["id"] + ".wav")
                file.write_bytes(response.content)
                subprocess.run([args.ffmpeg, "-v", "error", "-i", str(file), "-f", "null", "-"], check=True, capture_output=True)
                audio.append({"duration": asset["duration"], "bytes": len(response.content), "sha256": asset["sha256"]})
            repeat = generate(request)
            assert repeat["id"] == job["id"]
            assert [a["id"] for a in repeat["assets"]] == [a["id"] for a in job["assets"]]
            assert engine.inputs == excerpts, "Repeated source ranges unnecessarily regenerated audio"
            result = {"companion_version": health["version"], "voice_name": args.voice_name,
                      "engine": "real external OmniVoice", "paired_device_api": "pass",
                      "exact_source_inputs": "pass", "unicode_scalar_timings": "pass",
                      "authenticated_checksum_download": "pass", "full_audio_decode": "pass",
                      "same_request_recovery": "pass", "audio": audio,
                      "physical_iphone_flow": "NOT RUN"}
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
