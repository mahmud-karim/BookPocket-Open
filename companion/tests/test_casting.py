import json
import time
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config

def client(tmp_path):
    app = create_app(Config(data_dir=tmp_path, admin_token="secret", dev=True), engines={}, start_worker=False)
    return TestClient(app, client=("127.0.0.1", 9000), headers={"Authorization": "Bearer secret"})

def test_exact_cast_ranges_and_hosted_opt_in(tmp_path):
    c = client(tmp_path)
    book = c.post("/v1/books", files={"file": ("story.txt", 'He held 🧭. "Hello," said Mia.')}).json()
    sid = book["chapters"][0]["segments"][0]["id"]
    cast = {"characters": [{"id": "mia", "name": "Mia", "aliases": ["keeper"], "voice_id": None}], "assignments": [{"id": "a", "segment_id": sid, "start_offset": 11, "end_offset": 19, "character_id": "mia", "confidence": .8, "reviewed": True}]}
    result = c.put(f"/v1/books/{book['id']}/cast", json=cast)
    assert result.status_code == 200, result.text
    assert c.get(f"/v1/books/{book['id']}/cast").json() == cast
    cast["assignments"].append({**cast["assignments"][0], "id": "b"})
    assert c.put(f"/v1/books/{book['id']}/cast", json=cast).status_code == 400
    cfg = c.put("/v1/admin/analyzer", json={"url": "https://example.org/v1", "model": "chosen-model", "api_key": "private"})
    assert cfg.status_code == 200
    assert "private" not in cfg.text
    assert c.post(f"/v1/books/{book['id']}/analyze", json={"allow_hosted": False}).status_code == 409

def test_api_key_never_follows_different_origin(tmp_path):
    c = client(tmp_path)
    c.put("/v1/admin/analyzer", json={"url": "https://first.example/v1", "model": "a", "api_key": "private"})
    c.put("/v1/admin/analyzer", json={"url": "https://second.example/v1", "model": "b"})
    assert not c.get("/v1/admin/analyzer").json()["has_api_key"]
    assert json.loads((tmp_path / "analyzer.json").read_text())["api_key"] is None
    assert c.put("/v1/admin/analyzer", json={"url": "http://remote.example/v1", "model": "bad"}).status_code == 400
