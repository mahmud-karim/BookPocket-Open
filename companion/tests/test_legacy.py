import io
import json
from pathlib import Path
import shutil
import wave
import zipfile
import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config

def archive():
    audio = io.BytesIO()
    with wave.open(audio, "wb") as wav:
        wav.setparams((1, 2, 24000, 0, "NONE", "not compressed")); wav.writeframes(b"\0\0" * 24000 * 4)
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as z:
        z.writestr("source.txt", "A compass 🧭 shines.\n\nThe boat returns.")
        z.writestr("recording.wav", audio.getvalue())
        z.writestr("legacy.json", json.dumps({"format_version": 1, "kind": "bookpocket_legacy", "books": [{"legacy_id": "old", "source": "source.txt", "title": "Legacy", "position": "0-3:7"}], "recordings": [{"book_legacy_id": "old", "path": "recording.wav", "title": "Saved take", "source_text": "A compass 🧭 shines."}], "voices": [{"path": "recording.wav", "name": "Original test reference"}], "pronunciation_rules": [{"term": "compass", "replacement": "navigation compass", "enabled": True}]}))
    return output.getvalue()

def test_legacy_preserves_audio_and_marks_position_unmapped(tmp_path):
    if not shutil.which("ffmpeg"): pytest.skip("FFmpeg required")
    app = create_app(Config(data_dir=tmp_path, dev=True, admin_token="local"), engines={}, start_worker=False)
    c = TestClient(app, client=("127.0.0.1", 3333), headers={"Authorization": "Bearer local"})
    content = archive()
    response = c.post("/v1/projects/import", files={"file": ("legacy.zip", content)})
    assert response.status_code == 200, response.text
    result = response.json()
    assert result["positions"][0]["mapping"] == "unmapped"
    assert result["positions"][0]["legacy_position"] == "0-3:7"
    recording = result["recordings"][0]
    assert recording["mapping"] == "text_match_without_timings"
    assert recording["asset"]["timings"] == []
    assert len(result["voices"]) == 1
    assert c.get(recording["asset"]["url"]).content[:4] == b"RIFF"
    assert c.get("/v1/legacy-recordings").json()["recordings"][0]["id"] == recording["id"]
    assert c.get("/v1/pronunciations").json()["pronunciation_rules"][0]["term"] == "compass"
    assert c.post("/v1/projects/import", files={"file": ("legacy.zip", content)}).json() == result

def test_legacy_archive_traversal_is_rejected(tmp_path):
    app = create_app(Config(data_dir=tmp_path, dev=True, admin_token="local"), engines={}, start_worker=False)
    c = TestClient(app, client=("127.0.0.1", 3333), headers={"Authorization": "Bearer local"})
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        z.writestr("legacy.json", '{}'); z.writestr("../outside.txt", "no")
    assert c.post("/v1/projects/import", files={"file": ("legacy.zip", out.getvalue())}).status_code == 400
    assert not (tmp_path.parent / "outside.txt").exists()
