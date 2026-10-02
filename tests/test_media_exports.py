"""Exercise real FFmpeg exports using explicit tone fixtures, never speech claims."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import uuid
import zipfile
import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config

FIXTURES = Path(__file__).parent / "fixtures"

class ToneEngine:
    id, version = "test-tone", "1"
    def info(self):
        return {"id": self.id, "name": "Test-only tone", "available": True, "supports_cloning": False, "languages": ["en"], "license": "Apache-2.0", "reason": None}
    def voices(self):
        return [{"id": "test-tone:voice", "name": "Test tone", "engine": self.id, "kind": "preset", "language": "en", "created_at": "2026-01-01T00:00:00Z"}]
    def synthesize(self, text, voice, output, language):
        output.write_bytes((FIXTURES / "test-tone.wav").read_bytes())

@pytest.fixture
def rendered(tmp_path):
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        pytest.fail("FFmpeg and FFprobe are required for media verification; install before running this suite")
    app = create_app(Config(data_dir=tmp_path / "companion", admin_token="media-test-only", dev=True), engines={"test-tone": ToneEngine()}, start_worker=False)
    with TestClient(app, client=("127.0.0.1", 1234), headers={"Authorization": "Bearer media-test-only"}) as client:
        raw = (FIXTURES / "lantern.epub").read_bytes()
        book = client.post("/v1/books", files={"file": ("lantern.epub", raw)}).json()
        selection = [chapter["segments"][1]["id"] for chapter in book["chapters"]]
        job = client.post("/v1/jobs", json={"request_id": str(uuid.uuid4()), "book_id": book["id"], "segment_ids": selection, "engine": "test-tone", "voice_id": "test-tone:voice"}).json()
        app.state.worker.run(job["id"])
        result = client.get("/v1/jobs/" + job["id"]).json()
        assert result["status"] == "completed", result.get("error")
        yield client, book, result, tmp_path

@pytest.mark.parametrize("format,codec", [("m4b", "aac"), ("mp3", "mp3")])
def test_export_is_decodable_with_chapters(rendered, format, codec):
    client, book, job, directory = rendered
    response = client.post(f'/v1/jobs/{job["id"]}/export', json={"format": format})
    assert response.status_code == 200, response.text
    asset = response.json()
    content = client.get(asset["url"]).content
    assert hashlib.sha256(content).hexdigest() == asset["sha256"]
    path = directory / f"export.{format}"
    path.write_bytes(content)
    report = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-show_chapters", "-of", "json", str(path)]))
    assert report["streams"][0]["codec_name"] == codec
    assert float(report["format"]["duration"]) == pytest.approx(sum(a["duration"] for a in job["assets"]), abs=0.15)
    assert [c["tags"]["title"] for c in report["chapters"]] == [c["title"] for c in book["chapters"]]
    assert float(report["chapters"][0]["start_time"]) == 0
    assert float(report["chapters"][0]["end_time"]) == float(report["chapters"][1]["start_time"])
    subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "null", "-"], check=True, capture_output=True)


def test_project_export_preserves_original_and_all_segment_hashes(rendered):
    client, book, job, _ = rendered
    asset = client.post(f'/v1/jobs/{job["id"]}/export', json={"format": "project"}).json()
    with zipfile.ZipFile(io.BytesIO(client.get(asset["url"]).content)) as archive:
        assert archive.testzip() is None
        assert archive.read("source.epub") == (FIXTURES / "lantern.epub").read_bytes()
        project = json.loads(archive.read("project.json"))
        assert project["book"]["source_sha256"] == book["source_sha256"]
        assert project["generation"]["segment_ids"] == job["segment_ids"]
        assert len([name for name in archive.namelist() if name.startswith("audio/")]) == len(job["assets"])
        for audio in job["assets"]:
            assert hashlib.sha256(archive.read(f'audio/{audio["id"]}.wav')).hexdigest() == audio["sha256"]
