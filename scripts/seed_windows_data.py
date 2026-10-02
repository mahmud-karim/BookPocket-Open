"""Seed/verify original fixture data with the installed companion during lifecycle CI."""
import argparse
import io
import json
from pathlib import Path
import wave
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.cli import certificate
from bookpocket_companion.models import Config

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["seed", "verify"])
parser.add_argument("--data-dir", type=Path, required=True)
parser.add_argument("--fixtures", type=Path, required=True)
parser.add_argument("--ffmpeg", required=True)
parser.add_argument("--record", type=Path, required=True)
args = parser.parse_args()
config = Config(data_dir=args.data_dir, admin_token="installer-fixture-only", dev=True, ffmpeg=args.ffmpeg)
certificate(config)
app = create_app(config, start_worker=False)
with TestClient(app, client=("127.0.0.1", 9876), headers={"Authorization": "Bearer installer-fixture-only"}) as client:
    original = (args.fixtures / "lantern.epub").read_bytes()
    if args.mode == "seed":
        response = client.post("/v1/books", files={"file": ("lantern.epub", original)})
        assert response.status_code == 200, response.text
        book = response.json()
        # Reference is a four-second tone, never human speech or a real cloned voice.
        with wave.open(str(args.fixtures / "test-tone.wav"), "rb") as tone:
            frames, rate = tone.readframes(tone.getnframes()), tone.getframerate()
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as reference:
            reference.setparams((1, 2, rate, 0, "NONE", "not compressed"))
            reference.writeframes(frames * 16)
        response = client.post("/v1/voices", data={"name": "Installer test tone", "engine": "qwen3", "language": "en"}, files={"reference": ("fixture.wav", buffer.getvalue(), "audio/wav")})
        assert response.status_code == 200, response.text
        voice = response.json()
        settings = client.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1234/v1", "model": "fixture-only"})
        assert settings.status_code == 200
        args.record.write_text(json.dumps({"book_id": book["id"], "voice_id": voice["id"]}), encoding="utf-8")
    else:
        record = json.loads(args.record.read_text())
        assert client.get(f'/v1/books/{record["book_id"]}/source').content == original
        voice = client.get(f'/v1/voices/{record["voice_id"]}').json()
        assert voice["name"] == "Installer test tone"
        reference = client.get(f'/v1/voices/{record["voice_id"]}/reference')
        assert reference.status_code == 200 and reference.content.startswith(b"RIFF")
        assert client.get("/v1/admin/analyzer").json()["model"] == "fixture-only"
print("Installed companion data " + args.mode + " passed.")
