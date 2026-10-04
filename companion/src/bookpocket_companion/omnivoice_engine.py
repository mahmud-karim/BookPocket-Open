"""Companion-owned runtime using the official Apache-2.0 OmniVoice package."""
import json
import subprocess
import sys
from pathlib import Path
from .engines import ManagedEngine
from .setup_process import run_setup

SOURCE_REVISION = "08be0b4ccbac3e13e374e86fbfead4b4cac343e2"
MODEL_REVISION = "c5fdb5ccb189668d56333f77ba2629f4cd7535f4"
MODEL_REPO = "k2-fsa/OmniVoice"
LICENSE = "Code Apache-2.0; pretrained weights CC-BY-NC; Higgs tokenizer community license"


class OmniVoiceEngine(ManagedEngine):
    def __init__(self, root):
        super().__init__(root, "omnivoice")

    @property
    def model_path(self):
        return self.root / "models" / MODEL_REVISION

    @property
    def version(self):
        return "omnivoice-adapter-1:" + SOURCE_REVISION + ":" + MODEL_REVISION + ":" + super().version

    def info(self):
        available = False
        try:
            marker = json.loads((self.root / "ready.json").read_text(encoding="utf-8"))
            available = (isinstance(marker, dict) and self.python.exists() and marker.get("validated_synthesis") is True
                         and marker.get("model_revision") == MODEL_REVISION
                         and marker.get("source_revision") == SOURCE_REVISION
                         and all((self.model_path / p).is_file() for p in
                                 ("config.json", "model.safetensors", "audio_tokenizer/config.json", "audio_tokenizer/model.safetensors")))
        except (OSError, ValueError, TypeError):
            pass
        return {"id": self.id, "name": "OmniVoice", "available": available,
                "supports_cloning": True, "requires_reference": True, "requires_transcript": True,
                "languages": ["en"], "license": LICENSE,
                "reason": None if available else "Install and test OmniVoice in this companion's Settings"}

    def environment(self):
        env = super().environment()
        env["BOOKPOCKET_OMNIVOICE_MODEL"] = str(self.model_path)
        # Model/tokenizer must come from the pinned complete local snapshot.
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        return env

    def install(self, cancel_event=None):
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "ready.json").unlink(missing_ok=True)
        env = self.environment()
        env.pop("HF_HUB_OFFLINE", None)
        env.pop("TRANSFORMERS_OFFLINE", None)
        with (self.root / "install.log").open("w", encoding="utf-8") as log:
            def run(command, **kwargs):
                kwargs.setdefault("env", env)
                return run_setup(command, cancel_event=cancel_event, check=True,
                                 stdout=log, stderr=log, **kwargs)
            run([sys.executable, "-m", "venv", str(self.root / "venv")])
            try:
                gpu = run_setup(["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"],
                                cancel_event=cancel_event, check=False, capture_output=True, text=True, timeout=10)
                cuda = gpu.returncode == 0 and int(gpu.stdout.strip().split(".")[0]) >= 570
            except (OSError, ValueError, subprocess.TimeoutExpired):
                cuda = False
            run([str(self.python), "-m", "pip", "install", "torch==2.11.0", "torchaudio==2.11.0",
                 "--index-url", "https://download.pytorch.org/whl/" + ("cu128" if cuda else "cpu")])
            run([str(self.python), "-m", "pip", "install", "transformers==5.10.0", "soundfile==0.13.1",
                 "https://github.com/k2-fsa/OmniVoice/archive/" + SOURCE_REVISION + ".zip"])
            hf = self.python.with_name("hf.exe" if sys.platform == "win32" else "hf")
            run([str(hf), "download", MODEL_REPO, "--revision", MODEL_REVISION,
                 "--local-dir", str(self.model_path)])
            run([str(hf), "cache", "verify", MODEL_REPO, "--revision", MODEL_REVISION,
                 "--local-dir", str(self.model_path), "--fail-on-missing-files"])
            probe = {"engine": self.id, "probe": True, "output": str(self.root / "probe.wav"),
                     "text": "Your audiobook studio is ready.", "voice": {}, "language": "en"}
            run([str(self.python), str(Path(__file__).with_name("engine_worker.py"))],
                input=json.dumps(probe), text=True, timeout=1800, env=self.environment())
        # A successful child exit alone is not a synthesis result.
        import wave
        with wave.open(str(self.root / "probe.wav"), "rb") as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 24000):
                raise ValueError("OmniVoice validation did not produce mono 24 kHz PCM")
            frames = audio.getnframes()
            if frames <= 0 or len(audio.readframes(frames)) != frames * 2:
                raise ValueError("OmniVoice validation produced empty or truncated audio")
        self.record_provenance(cancel_event=cancel_event, validated_synthesis=True,
                               model_revision=MODEL_REVISION, source_revision=SOURCE_REVISION,
                               model_repo=MODEL_REPO, license=LICENSE)
