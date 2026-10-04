"""Executed only in an engine's isolated interpreter. Never imported by API server."""
import json
import sys
from contextlib import redirect_stdout

pipelines = {}
qwen_model = None
omnivoice_model = None
omnivoice_prompts = {}

def generate(data):
    global qwen_model, omnivoice_model
    import numpy as np
    import soundfile as sf
    if data["engine"] == "omnivoice":
        import os
        import torch
        from pathlib import Path
        from omnivoice import OmniVoice
        root = Path(os.environ["BOOKPOCKET_OMNIVOICE_MODEL"])
        if not (root / "audio_tokenizer/model.safetensors").is_file():
            raise ValueError("The pinned OmniVoice tokenizer is missing; reinstall OmniVoice")
        if omnivoice_model is None:
            device = "cuda:0" if torch.cuda.is_available() else "cpu"
            dtype = torch.bfloat16 if device != "cpu" and torch.cuda.is_bf16_supported() else torch.float32
            omnivoice_model = OmniVoice.from_pretrained(str(root), device_map=device, dtype=dtype,
                                                       attn_implementation="sdpa", load_asr=False)
        options = {"text": data["text"], "language": data["language"], "normalize_text": False}
        if not data.get("probe"):
            voice = data["voice"]
            if not voice.get("reference") or not voice.get("transcript", "").strip():
                raise ValueError("OmniVoice needs reference audio and its transcript")
            import hashlib
            key = (hashlib.sha256(Path(voice["reference"]).read_bytes()).hexdigest(), voice["transcript"])
            if key not in omnivoice_prompts:
                omnivoice_prompts[key] = omnivoice_model.create_voice_clone_prompt(
                    ref_audio=voice["reference"], ref_text=voice["transcript"])
            options["voice_clone_prompt"] = omnivoice_prompts[key]
        audio = np.asarray(omnivoice_model.generate(**options)[0])
        if not audio.size or not np.isfinite(audio).all(): raise ValueError("OmniVoice returned invalid audio")
        sf.write(data["output"], audio, omnivoice_model.sampling_rate, subtype="PCM_16")
    elif data["engine"] == "kokoro":
        from kokoro import KPipeline
        voice = data["voice"]["id"].split(":", 1)[-1]
        lang_code = "b" if voice.startswith("b") else "a"
        if lang_code not in pipelines: pipelines[lang_code] = KPipeline(lang_code=lang_code, repo_id="hexgrad/Kokoro-82M")
        pipeline = pipelines[lang_code]
        chunks, timings, audio_cursor = [], [], 0.0
        for result in pipeline(data["text"], voice=voice):
            audio = np.asarray(result.audio)
            chunks.append(audio)
            for token in result.tokens or []:
                start, end = getattr(token, "start_ts", None), getattr(token, "end_ts", None)
                if start is not None and end is not None and token.text.strip():
                    timings.append({"text": token.text, "start": audio_cursor + float(start), "end": audio_cursor + float(end)})
            audio_cursor += len(audio) / 24000
        if not chunks: raise ValueError("Engine returned no audio")
        sf.write(data["output"], np.concatenate(chunks), 24000, subtype="PCM_16")
        return {"words": timings}
    else:
        import torch
        from qwen_tts import Qwen3TTSModel
        device = "cuda:0" if torch.cuda.is_available() else "cpu"
        if qwen_model is None:
            qwen_model = Qwen3TTSModel.from_pretrained("Qwen/Qwen3-TTS-12Hz-0.6B-Base", device_map=device,
                        dtype=torch.bfloat16 if device != "cpu" and torch.cuda.is_bf16_supported() else torch.float32, attn_implementation="sdpa")
        if data.get("probe"):
            # The Base model requires user reference audio; successful model load validates setup.
            return
        voice = data["voice"]
        if not voice.get("reference"): raise ValueError("Choose a cloned voice with reference audio")
        languages = {"en": "English", "zh": "Chinese", "ja": "Japanese", "ko": "Korean", "de": "German", "fr": "French", "ru": "Russian", "pt": "Portuguese", "es": "Spanish", "it": "Italian"}
        wavs, sr = qwen_model.generate_voice_clone(text=data["text"], language=languages[data["language"]], ref_audio=voice["reference"],
                    ref_text=voice.get("transcript") or None, x_vector_only_mode=not bool(voice.get("transcript")))
        sf.write(data["output"], wavs[0], sr, subtype="PCM_16")

def main():
    for line in sys.stdin:
        try:
            data = json.loads(line)
            with redirect_stdout(sys.stderr): result = generate(data)
            print(json.dumps({"ok": True, **(result or {})}), flush=True)
        except Exception as exc:
            print(json.dumps({"ok": False, "error": str(exc)[:1500]}), flush=True)
            if data.get("probe"): raise

if __name__ == "__main__": main()
