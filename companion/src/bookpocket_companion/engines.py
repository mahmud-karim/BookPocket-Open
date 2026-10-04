"""Clean adapters. Model dependencies live in separate environments."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import httpx
import hashlib
from .setup_process import run_setup
from .scheduler import WorkCancelled, WorkOwnershipUncertain


def python_in(root):
    return root / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


class ManagedEngine:
    def __init__(self, root, engine_id):
        self.id = engine_id
        self.root = root / engine_id
        self.python = python_in(self.root / "venv")
        self.process = None
        self.log_handle = None

    @property
    def version(self):
        marker = self.root / "ready.json"
        provenance = json.loads(marker.read_text(encoding="utf-8")).get("provenance", {}) if marker.exists() else {}
        fingerprint = hashlib.sha256(json.dumps(provenance, sort_keys=True).encode()).hexdigest()[:16]
        return "adapter-3:" + fingerprint

    def record_provenance(self, cancel_event=None, **extra):
        result = run_setup([str(self.python), "-c", "import importlib.metadata,json; print(json.dumps({d.metadata['Name']:d.version for d in importlib.metadata.distributions()}))"], cancel_event=cancel_event, capture_output=True, text=True, check=True, timeout=30)
        snapshots = sorted(str(path.relative_to(self.root / "models" / "hub")).replace("\\", "/") for path in (self.root / "models" / "hub").glob("models--*/snapshots/*") if path.is_dir())
        provenance = {"packages": json.loads(result.stdout), "model_snapshots": snapshots, "adapter": 3}
        marker = {"provenance": provenance, **extra}
        temporary = self.root / "ready.tmp"
        temporary.write_text(json.dumps(marker, sort_keys=True), encoding="utf-8")
        if cancel_event is not None and cancel_event.is_set(): raise WorkCancelled("Model setup stopped")
        temporary.replace(self.root / "ready.json")

    def info(self):
        available = self.python.exists() and (self.root / "ready.json").exists()
        return {"id": self.id, "name": "Kokoro" if self.id == "kokoro" else "Qwen3 TTS 0.6B",
                "available": available, "supports_cloning": self.id == "qwen3",
                "languages": ["en"] if self.id == "kokoro" else ["en", "zh", "ja", "ko", "de", "fr", "ru", "pt", "es", "it"], "license": "Apache-2.0",
                "requires_reference": self.id == "qwen3",
                "reason": None if available else "Install and validate this engine in Settings"}

    def voices(self):
        if self.id != "kokoro" or not self.info()["available"]: return []
        return [{"id": "kokoro:" + name, "name": label, "engine": "kokoro", "kind": "preset", "language": "en", "created_at": "2025-01-27T00:00:00Z"}
                for name, label in [("af_heart", "Heart"), ("af_bella", "Bella"), ("am_adam", "Adam"), ("bm_george", "George")]]

    def synthesize(self, text, voice, output, language="en"):
        if not self.info()["available"]: raise RuntimeError("The selected model is not installed and validated")
        payload = {"engine": self.id, "text": text, "voice": voice, "output": str(output), "language": language}
        if not self.process or self.process.poll() is not None:
            self.close()
            self.log_handle = (self.root / "generation.log").open("a", encoding="utf-8")
            self.process = subprocess.Popen([str(self.python), "-u", str(Path(__file__).with_name("engine_worker.py"))], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=self.log_handle, text=True, encoding="utf-8", env=self.environment())
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()
        # One worker exclusively owns this subprocess; read in a bounded future to recover a hung model.
        import concurrent.futures
        executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        future = executor.submit(self.process.stdout.readline)
        try:
            line = future.result(timeout=1800)
            if not line: raise RuntimeError("Engine process stopped; inspect the local generation log")
            result = json.loads(line)
            if not result.get("ok"): raise RuntimeError(result.get("error", "Engine generation failed"))
            return result
        except BaseException:
            self.close()
            raise
        finally:
            executor.shutdown(wait=False, cancel_futures=True)

    def close(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                try: self.process.wait(timeout=5)
                except subprocess.TimeoutExpired as exc: raise WorkOwnershipUncertain("The model process did not stop") from exc
        self.process = None
        if self.log_handle: self.log_handle.close()
        self.log_handle = None

    def environment(self):
        env = dict(os.environ)
        env["HF_HOME"] = str(self.root / "models")
        env["HF_HUB_CACHE"] = str(self.root / "models" / "hub")
        env["HUGGINGFACE_HUB_CACHE"] = env["HF_HUB_CACHE"]
        env["TRANSFORMERS_CACHE"] = env["HF_HUB_CACHE"]
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["PYTHONUTF8"] = "1"
        return env

    def install(self, cancel_event=None):
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "ready.json").unlink(missing_ok=True)
        log = self.root / "install.log"
        packages = ["kokoro==0.9.4", "soundfile", "numpy", "misaki[en]", "en-core-web-sm@https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"] if self.id == "kokoro" else ["qwen-tts==0.1.1", "soundfile"]
        with log.open("w", encoding="utf-8") as out:
            run_setup([sys.executable, "-m", "venv", str(self.root / "venv")], cancel_event=cancel_event, check=True, stdout=out, stderr=out)
            run_setup([str(self.python), "-m", "pip", "install", *packages], cancel_event=cancel_event, check=True, stdout=out, stderr=out, env=self.environment())
            try:
                gpu = run_setup(["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"], cancel_event=cancel_event, check=False, capture_output=True, text=True, timeout=10)
                modern_cuda = gpu.returncode == 0 and int(gpu.stdout.strip().split(".")[0]) >= 570
            except (OSError, ValueError, subprocess.TimeoutExpired): modern_cuda = False
            if modern_cuda:
                run_setup([str(self.python), "-m", "pip", "install", "torch==2.11.0", "torchaudio==2.11.0", "--index-url", "https://download.pytorch.org/whl/cu128"], cancel_event=cancel_event, check=True, stdout=out, stderr=out, env=self.environment())
            # Kokoro performs a real synthesis; Qwen Base loads the model, then requires a user voice reference.
            probe = {"engine": self.id, "probe": True, "output": str(self.root / "probe.wav"), "text": "Your audiobook studio is ready.", "voice": {"id": "kokoro:af_heart"}, "language": "en"}
            run_setup([str(self.python), str(Path(__file__).with_name("engine_worker.py"))], cancel_event=cancel_event, input=json.dumps(probe), text=True,
                           check=True, stdout=out, stderr=out, env=self.environment(), timeout=1800)
        self.record_provenance(cancel_event=cancel_event, validated_synthesis=self.id == "kokoro", validated_model_load=True)


class VoiceStudioEngine:
    id = "voicestudio"
    version = "speech-v1"
    def __init__(self, url):
        self.url = url.rstrip("/") if url else None

    def inventory(self):
        if not self.url: raise RuntimeError("Configure the optional local VoiceStudio service")
        response = httpx.get(self.url + "/v1/audio/voices", timeout=3)
        response.raise_for_status()
        return response.json()

    def info(self):
        try:
            inventory = self.inventory()
            configured = next((e for e in inventory.get("engines", []) if e.get("id") == "omnivoice"), None)
            available = bool(configured and configured.get("available"))
            reason = None if available else "Start the OmniVoice engine in VoiceStudio"
        except Exception:
            available, reason = False, "VoiceStudio is not configured or is not running"
        return {"id": self.id, "name": "VoiceStudio (external)", "available": available, "supports_cloning": False,
                "languages": ["en"], "license": "External service; OmniVoice weights are noncommercial", "reason": reason}

    def voices(self):
        try: result = self.inventory()
        except Exception: return []
        items = result if isinstance(result, list) else result.get("voices", result.get("data", []))
        return [{"id": "voicestudio:" + str(v.get("id", v.get("voice_id"))), "name": v.get("name", "VoiceStudio voice"),
                 "engine": self.id, "kind": "clone" if v.get("type") == "profile" else "preset", "language": "en", "created_at": v.get("created_at", "2026-01-01T00:00:00Z")}
                for v in items if isinstance(v, dict) and (v.get("id") or v.get("voice_id")) and v.get("type") != "openai_alias"]

    def synthesize(self, text, voice, output, language="en"):
        with httpx.stream("POST", self.url + "/v1/audio/speech", json={"model": "omnivoice", "input": text, "language": language,
                          "voice": voice["id"].removeprefix("voicestudio:"), "response_format": "wav"}, timeout=1800) as response:
            response.raise_for_status()
            with output.open("wb") as f:
                for chunk in response.iter_bytes(): f.write(chunk)


def engines_for(config):
    from .omnivoice_engine import OmniVoiceEngine
    return {"kokoro": ManagedEngine(config.data_dir / "engines", "kokoro"),
            "qwen3": ManagedEngine(config.data_dir / "engines", "qwen3"),
            "omnivoice": OmniVoiceEngine(config.data_dir / "engines"),
            "voicestudio": VoiceStudioEngine(config.voicestudio_url)}
