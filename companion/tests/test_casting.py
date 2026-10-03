import json
import time
import threading
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion.casting import source_assignment
from bookpocket_companion.casting import dialogue_units, resolve_utterances
import pytest

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

def test_verbatim_source_anchors_resolve_scalar_offsets_without_rewriting():
    text = 'A 🧭. "Hello," said Mia. "Hello," said Leo.'
    assignment = source_assignment({"segment_id": "s", "source_text": '"Hello,"', "occurrence": 2, "character_id": "leo", "confidence": .8}, {"s": text})
    assert assignment.start_offset == text.rfind('"Hello,"')
    assert text[assignment.start_offset:assignment.end_offset] == '"Hello,"'
    assert not assignment.reviewed
    with pytest.raises(ValueError, match="ambiguous"):
        source_assignment({"segment_id": "s", "source_text": '"Hello,"', "character_id": "leo", "confidence": .8}, {"s": text})
    with pytest.raises(ValueError, match="missing"):
        source_assignment({"segment_id": "s", "source_text": 'Rewritten words', "character_id": "leo", "confidence": .8}, {"s": text})


def test_utterance_boundaries_and_strict_model_identity():
    text = 'A 🧭. “Hello,” said Mia. "Hello," said Leo. «Goodbye.»'
    units = dialogue_units([{"segment_id": "s", "text": text}])
    assert [u["source_text"] for u in units] == ['“Hello,”', '"Hello,"', '«Goodbye.»']
    result = {"assignments": [{"utterance_id": u["utterance_id"], "source_text": u["source_text"], "character_id": c, "confidence": .8} for u, c in zip(units, ["mia", "leo", "mia"])]}
    resolved = resolve_utterances(result, units, {"mia", "leo"})
    assert [text[a.start_offset:a.end_offset] for a in resolved] == [u["source_text"] for u in units]
    assert all(not a.reviewed for a in resolved)
    result["assignments"][0]["utterance_id"] = "invented"
    with pytest.raises(ValueError, match="unknown"): resolve_utterances(result, units, {"mia", "leo"})
    result["assignments"][0]["utterance_id"] = units[0]["utterance_id"]
    result["assignments"][0]["source_text"] = "Rewritten"
    with pytest.raises(ValueError, match="exact"): resolve_utterances(result, units, {"mia", "leo"})
    with pytest.raises(ValueError, match="omitted"): resolve_utterances({"assignments": []}, units, {"mia", "leo"})


@pytest.mark.parametrize("text", ['“Not closed', '“She said ‘go’.”', '‘Single quoted speech.’', '"She said \'go\'."'])
def test_unsupported_dialogue_requires_review(text):
    with pytest.raises(ValueError, match="review"):
        dialogue_units([{"segment_id": "s", "text": text}])


@pytest.mark.parametrize("apostrophe", ["'", "’"])
@pytest.mark.parametrize("opening,closing", [('"', '"'), ('“', '”')])
def test_plural_possessive_inside_dialogue_preserves_exact_source(apostrophe, opening, closing):
    text = f'A 🧭. {opening}The pilots{apostrophe} maps are ready,{closing} said Mira.'
    units = dialogue_units([{"segment_id": "s", "text": text}])
    assert len(units) == 1
    assert units[0]["source_text"] == f'{opening}The pilots{apostrophe} maps are ready,{closing}'
    assert text[units[0]["start_offset"]:units[0]["end_offset"]] == units[0]["source_text"]


@pytest.mark.parametrize("text", ['“She said ‘pilots’ maps.”', '"She said \'pilots\' maps."', '“The word ends’.”'])
def test_plural_possessive_exception_does_not_swallow_nested_or_ambiguous_quotes(text):
    with pytest.raises(ValueError, match="review"):
        dialogue_units([{"segment_id": "s", "text": text}])


def test_inflight_analysis_preserves_saved_edits_and_deletions_after_reconstruction(tmp_path, monkeypatch):
    """Delay explicit fixture transport while real API requests modify persisted cast."""
    import httpx
    c = client(tmp_path)
    text = 'A 🧭. “The pilots’ maps are ready,” said Mira. “Wait,” said Mira. “Gone,” said Leo. “Here,” said Mira. “New,” said Ada.'
    book = c.post("/v1/books", files={"file": ("original.txt", text)}).json()
    segment = book["chapters"][0]["segments"][0]
    units = dialogue_units([{"segment_id": segment["id"], "text": segment["text"]}])
    def assignment(index, identity, character="mira", reviewed=True):
        return {"id": identity, "segment_id": segment["id"], "start_offset": units[index]["start_offset"],
                "end_offset": units[index]["end_offset"], "character_id": character, "confidence": .8, "reviewed": reviewed}
    original_cast = {"characters": [{"id": "mira", "name": "Mira", "aliases": ["Captain", "Pilot"], "voice_id": "old-voice"},
                                    {"id": "leo", "name": "Leo", "aliases": [], "voice_id": None}],
                     "assignments": [assignment(0, "kept"), assignment(1, "deleted-span"), assignment(2, "deleted-character", "leo"), assignment(3, "edited-unreviewed", reviewed=False)]}
    route = f"/v1/books/{book['id']}/cast"
    assert c.put(route, json=original_cast).status_code == 200
    assert c.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1234/v1", "model": "delayed-fixture-only"}).status_code == 200
    entered, release = threading.Event(), threading.Event()
    original_post = httpx.Client.post
    def respond(self, url, **kwargs):
        if not str(url).endswith("/chat/completions"):
            return original_post(self, url, **kwargs)
        prompt = json.loads(kwargs["json"]["messages"][1]["content"])
        entered.set()
        assert release.wait(10), "Test did not release fixture transport"
        result = {"characters": [{"id": "mira", "name": "Model name", "aliases": ["Captain", "Pilot", "Model alias"]},
                                 {"id": "leo", "name": "Model Leo", "aliases": []}, {"id": "ada", "name": "Ada", "aliases": []}],
                  "assignments": [{"utterance_id": u["utterance_id"], "source_text": u["source_text"], "character_id": name, "confidence": .9}
                                  for u, name in zip(prompt["utterances"], ["mira", "mira", "leo", "mira", "ada"])]}
        return httpx.Response(200, request=httpx.Request("POST", url), json={"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(result)}}]})
    monkeypatch.setattr(httpx.Client, "post", respond)
    job = c.post(f"/v1/books/{book['id']}/analyze", json={}).json()
    try:
        assert entered.wait(5), "Analysis never reached fixture transport"
        kept = {**original_cast["assignments"][0], "start_offset": units[0]["start_offset"] + 1, "confidence": 1}
        unreviewed = {**original_cast["assignments"][3], "end_offset": units[3]["end_offset"] - 1, "confidence": .4}
        saved = {"characters": [{"id": "mira", "name": "My Mira", "aliases": [], "voice_id": "new-voice"}], "assignments": [kept, unreviewed]}
        assert c.put(route, json=saved).status_code == 200
    finally:
        release.set()
    for _ in range(200):
        job = c.get('/v1/analyses/' + job['id']).json()
        if job["status"] not in {"queued", "running"}: break
        time.sleep(.02)
    assert job["status"] == "completed", job
    cast = c.get(route).json()
    assert next(character for character in cast["characters"] if character["id"] == "mira") == saved["characters"][0]
    assert all(character["id"] != "leo" for character in cast["characters"])
    assert kept in cast["assignments"] and unreviewed in cast["assignments"]
    assert len(cast["assignments"]) == 3
    fresh = next(a for a in cast["assignments"] if a["id"] not in {"kept", "edited-unreviewed"})
    assert fresh["character_id"] == "ada" and not fresh["reviewed"]
    assert fresh["start_offset"] == units[4]["start_offset"]
    c.close()
    # Reconstruct the application and Store over the same SQLite database.
    with client(tmp_path) as reconstructed:
        assert reconstructed.get(route).json() == cast
        assert reconstructed.get('/v1/analyses/' + job['id']).json()["status"] == "completed"


@pytest.mark.parametrize("initially_empty", [False, True])
def test_inflight_clear_all_preserved_but_initially_empty_cast_can_be_analyzed(tmp_path, monkeypatch, initially_empty):
    import httpx
    c = client(tmp_path)
    book = c.post("/v1/books", files={"file": ("original.txt", '“Ready,” said Mira.')}).json()
    segment = book["chapters"][0]["segments"][0]
    unit = dialogue_units([{"segment_id": segment["id"], "text": segment["text"]}])[0]
    empty = {"characters": [], "assignments": []}
    initial = empty if initially_empty else {
        "characters": [{"id": "previous", "name": "Previous speaker", "aliases": [], "voice_id": "my-voice"}],
        "assignments": [{"id": "previous-span", "segment_id": segment["id"], "start_offset": unit["start_offset"],
                         "end_offset": unit["end_offset"], "character_id": "previous", "confidence": 1, "reviewed": True}]}
    route = f"/v1/books/{book['id']}/cast"
    assert c.put(route, json=initial).status_code == 200
    assert c.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1234/v1", "model": "delayed-fixture-only"}).status_code == 200
    entered, release = threading.Event(), threading.Event()
    original_post = httpx.Client.post
    def respond(self, url, **kwargs):
        if not str(url).endswith("/chat/completions"):
            return original_post(self, url, **kwargs)
        prompt = json.loads(kwargs["json"]["messages"][1]["content"])
        utterance = prompt["utterances"][0]
        entered.set()
        assert release.wait(10), "Test did not release fixture transport"
        result = {"characters": [{"id": "mira", "name": "Mira", "aliases": []}], "assignments": [
            {"utterance_id": utterance["utterance_id"], "source_text": utterance["source_text"], "character_id": "mira", "confidence": .9}]}
        return httpx.Response(200, request=httpx.Request("POST", url), json={"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(result)}}]})
    monkeypatch.setattr(httpx.Client, "post", respond)
    job = c.post(f"/v1/books/{book['id']}/analyze", json={}).json()
    try:
        assert entered.wait(5), "Analysis never reached fixture transport"
        assert c.put(route, json=empty).status_code == 200
    finally:
        release.set()
    for _ in range(200):
        job = c.get('/v1/analyses/' + job['id']).json()
        if job["status"] not in {"queued", "running"}: break
        time.sleep(.02)
    assert job["status"] == "completed", job
    cast = c.get(route).json()
    if initially_empty:
        assert [character["id"] for character in cast["characters"]] == ["mira"]
        assert len(cast["assignments"]) == 1
        assert cast["assignments"][0]["character_id"] == "mira"
    else:
        assert cast == empty
    c.close()
    with client(tmp_path) as reconstructed:
        assert reconstructed.get(route).json() == cast


def test_analysis_preserves_reviewed_edits_and_reports_unsupported(tmp_path, monkeypatch):
    import httpx
    c = client(tmp_path)
    book = c.post("/v1/books", files={"file": ("story.txt", 'A 🧭. “Hello,” said Mia. “Goodbye,” said Leo.')}).json()
    segment = book["chapters"][0]["segments"][0]
    units = dialogue_units([{"segment_id": segment["id"], "text": segment["text"]}])
    reviewed = {"id": "reviewed", "segment_id": segment["id"], "start_offset": units[0]["start_offset"], "end_offset": units[0]["end_offset"], "character_id": "corrected", "confidence": 1, "reviewed": True}
    saved = {"characters": [{"id": "corrected", "name": "My correction", "voice_id": "my-voice"}], "assignments": [reviewed]}
    c.put(f"/v1/books/{book['id']}/cast", json=saved)
    c.put("/v1/admin/analyzer", json={"url": "http://127.0.0.1:1234/v1", "model": "fixture-transport"})
    original = httpx.Client.post
    def respond(self, url, **kwargs):
        if str(url).endswith("/chat/completions"):
            prompt = json.loads(kwargs["json"]["messages"][1]["content"])
            result = {"characters": [{"id": "mia", "name": "Mia"}, {"id": "leo", "name": "Leo"}], "assignments": [{"utterance_id": u["utterance_id"], "source_text": u["source_text"], "character_id": name, "confidence": .9} for u, name in zip(prompt["utterances"], ["mia", "leo"])]}
            return httpx.Response(200, request=httpx.Request("POST", url), json={"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(result)}}]})
        return original(self, url, **kwargs)
    monkeypatch.setattr(httpx.Client, "post", respond)
    job = c.post(f"/v1/books/{book['id']}/analyze", json={}).json()
    for _ in range(100):
        job = c.get('/v1/analyses/'+job['id']).json()
        if job["status"] not in {"queued", "running"}: break
        time.sleep(.02)
    assert job["status"] == "completed", job
    assert job["warnings"]
    cast = c.get(f"/v1/books/{book['id']}/cast").json()
    assert reviewed in cast["assignments"]
    assert next(c for c in cast["characters"] if c["id"] == "corrected")["voice_id"] == "my-voice"
    assert len(cast["assignments"]) == 2
    assert next(a for a in cast["assignments"] if not a["reviewed"])["character_id"] == "leo"
    unquoted = c.post("/v1/books", files={"file": ("script.txt", "MIA: Hello there.")}).json()
    job = c.post(f"/v1/books/{unquoted['id']}/analyze", json={}).json()
    for _ in range(100):
        job = c.get('/v1/analyses/'+job['id']).json()
        if job["status"] not in {"queued", "running"}: break
        time.sleep(.02)
    assert job["status"] == "failed"
    assert "unquoted" in job["error"]
