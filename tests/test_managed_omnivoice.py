"""Runtime boundaries using explicit test fixtures; never download or claim real models."""
import json
import subprocess
import threading
import wave
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion.omnivoice_engine import OmniVoiceEngine, MODEL_REVISION, SOURCE_REVISION
from bookpocket_companion.scheduler import WorkCancelled


def files(engine):
    engine.python.parent.mkdir(parents=True, exist_ok=True)
    engine.python.touch()
    for name in ("config.json", "model.safetensors", "audio_tokenizer/config.json", "audio_tokenizer/model.safetensors"):
        path = engine.model_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"explicit test-only model placeholder")


@pytest.mark.parametrize("damage", ["none", "list", "invalid_json", "wrong_source", "wrong_model", "not_tested", "missing_tokenizer"])
def test_readiness_requires_matching_provenance_and_complete_local_model(tmp_path, damage):
    engine = OmniVoiceEngine(tmp_path)
    files(engine)
    marker = {"validated_synthesis": True, "source_revision": SOURCE_REVISION, "model_revision": MODEL_REVISION}
    if damage == "list": marker = []
    if damage == "wrong_source": marker["source_revision"] = "unknown"
    if damage == "wrong_model": marker["model_revision"] = "unknown"
    if damage == "not_tested": marker["validated_synthesis"] = False
    if damage == "missing_tokenizer": (engine.model_path / "audio_tokenizer/config.json").unlink()
    (engine.root / "ready.json").write_text("not JSON" if damage == "invalid_json" else json.dumps(marker))
    assert engine.info()["available"] is (damage == "none")
    assert engine.info()["requires_transcript"]
    assert engine.environment()["HF_HUB_OFFLINE"] == "1"
    assert engine.environment()["BOOKPOCKET_OMNIVOICE_MODEL"] == str(engine.model_path)


@pytest.mark.parametrize("result", ["valid", "empty", "wrong_rate", "cancelled", "process_failed"])
def test_install_requires_actual_pcm_result_and_never_publishes_failed_readiness(tmp_path, monkeypatch, result):
    import bookpocket_companion.omnivoice_engine as module
    import bookpocket_companion.engines as base
    engine = OmniVoiceEngine(tmp_path)
    files(engine)
    (engine.root / "ready.json").write_text("old installation")
    cancelled = threading.Event()
    commands = []
    def run(command, **kwargs):
        commands.append(command)
        if command[0] == "nvidia-smi": return subprocess.CompletedProcess(command, 0, "581.00", "")
        if command[-1].endswith("engine_worker.py"):
            if result == "process_failed": raise subprocess.CalledProcessError(1, command)
            probe = json.loads(kwargs["input"])
            with wave.open(probe["output"], "wb") as audio:
                audio.setparams((1, 2, 16000 if result == "wrong_rate" else 24000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\0\0" * (0 if result == "empty" else 2400))
            if result == "cancelled": cancelled.set()
        return subprocess.CompletedProcess(command, 0, "{}", "")
    monkeypatch.setattr(module, "run_setup", run)
    monkeypatch.setattr(base, "run_setup", run)
    if result == "valid":
        engine.install(cancelled)
        assert engine.info()["available"]
        assert MODEL_REVISION in engine.version and SOURCE_REVISION in engine.version
        assert any("--fail-on-missing-files" in command for command in commands)
        assert any("cu128" in " ".join(command) for command in commands)
    else:
        with pytest.raises((ValueError, WorkCancelled, subprocess.CalledProcessError)):
            engine.install(cancelled)
        assert not (engine.root / "ready.json").exists()
        assert not engine.info()["available"]


def test_voice_import_rejects_missing_transcript_before_creating_private_files(tmp_path):
    engine = OmniVoiceEngine(tmp_path / "engines")
    config = Config(data_dir=tmp_path / "data", admin_token="test-only-admin", dev=True)
    app = create_app(config, engines={engine.id: engine}, start_worker=False)
    with TestClient(app, client=("127.0.0.1", 1), headers={"Authorization": "Bearer test-only-admin"}) as client:
        response = client.post("/v1/voices", data={"engine": engine.id, "name": "Fixture", "transcript": "  "},
                               files={"reference": ("fixture.wav", b"not actual voice audio", "audio/wav")})
        assert response.status_code == 400
        assert "transcript" in response.json()["detail"]
        assert client.get("/v1/voices").json() == {"voices": []}
        assert not list((config.data_dir / "voices").glob("*.wav"))


@pytest.fixture
def isolated_worker(tmp_path, monkeypatch):
    from bookpocket_companion import engine_worker
    # Explicit model/array fixtures exercise the isolated adapter without ML dependencies.
    root = tmp_path / "snapshot"
    (root / "audio_tokenizer").mkdir(parents=True)
    (root / "audio_tokenizer/model.safetensors").touch()
    monkeypatch.setenv("BOOKPOCKET_OMNIVOICE_MODEL", str(root))
    calls = {"load": [], "prompt": [], "generate": [], "write": [], "samples": [.1] * 2400, "finite": True}
    class Model:
        sampling_rate = 24000
        @classmethod
        def from_pretrained(cls, path, **options):
            calls["load"].append((path, options))
            return cls()
        def create_voice_clone_prompt(self, **options):
            calls["prompt"].append(options)
            return object()
        def generate(self, **options):
            calls["generate"].append(options)
            return [calls["samples"]]
    array = lambda samples: SimpleNamespace(size=len(samples), samples=samples)
    def write(path, audio, rate, subtype):
        calls["write"].append((path, rate, subtype))
        with wave.open(path, "wb") as wav:
            wav.setparams((1, 2, rate, 0, "NONE", "not compressed"))
            wav.writeframes(b"\0\0" * len(audio.samples))
    monkeypatch.setitem(sys.modules, "numpy", SimpleNamespace(asarray=array, isfinite=lambda audio: SimpleNamespace(all=lambda: calls["finite"])))
    monkeypatch.setitem(sys.modules, "soundfile", SimpleNamespace(write=write))
    monkeypatch.setitem(sys.modules, "torch", SimpleNamespace(cuda=SimpleNamespace(is_available=lambda: False), float32="fixture-float32"))
    monkeypatch.setitem(sys.modules, "omnivoice", SimpleNamespace(OmniVoice=Model))
    monkeypatch.setattr(engine_worker, "omnivoice_model", None)
    monkeypatch.setattr(engine_worker, "omnivoice_prompts", {})
    reference = tmp_path / "reference.wav"
    reference.write_bytes(b"explicit test-only reference bytes")
    payload = {"engine": "omnivoice", "text": "The compass 🧭 points north.", "language": "en",
               "voice": {"reference": str(reference), "transcript": "Exact fixture words."}, "output": str(tmp_path / "result.wav")}
    return engine_worker, calls, payload


def test_isolated_adapter_keeps_exact_source_disables_asr_and_rebuilds_changed_reference_prompt(isolated_worker):
    worker, calls, payload = isolated_worker
    worker.generate(payload)
    worker.generate(payload)
    assert len(calls["load"]) == 1 and len(calls["prompt"]) == 1
    assert calls["load"][0][1]["load_asr"] is False
    assert calls["load"][0][1]["attn_implementation"] == "sdpa"
    assert calls["prompt"][0]["ref_text"] == payload["voice"]["transcript"]
    assert all(c["text"] == payload["text"] and c["language"] == "en" and c["normalize_text"] is False for c in calls["generate"])
    Path(payload["voice"]["reference"]).write_bytes(b"changed test-only reference")
    worker.generate(payload)
    assert len(calls["prompt"]) == 2
    assert all((rate, subtype) == (24000, "PCM_16") for _, rate, subtype in calls["write"])


@pytest.mark.parametrize("damage", ["empty", "nonfinite", "missing_transcript"])
def test_isolated_adapter_refuses_invalid_output_or_missing_clone_text(isolated_worker, damage):
    worker, calls, payload = isolated_worker
    if damage == "empty": calls["samples"] = []
    if damage == "nonfinite": calls["finite"] = False
    if damage == "missing_transcript": payload["voice"]["transcript"] = " "
    with pytest.raises(ValueError): worker.generate(payload)
    assert not calls["write"] and not Path(payload["output"]).exists()
