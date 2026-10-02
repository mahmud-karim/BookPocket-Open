import json
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import wave
from pathlib import Path
from .store import canonical, digest, now

def sentences(text):
    # Python string offsets count Unicode scalars, matching the wire contract.
    for match in re.finditer(r"\S[\s\S]*?(?:[.!?](?=\s|$)|$)", text):
        if match.group().strip():
            yield match.start(), match.end(), match.group()

def spoken(text, rules):
    return spoken_mapping(text, rules)[0]

def spoken_mapping(text, rules):
    mapping = [(i, i+1) for i in range(len(text))]
    for rule in rules:
        if rule["enabled"]:
            pattern = re.compile(r"(?<!\w)" + re.escape(rule["term"]) + r"(?!\w)", re.IGNORECASE)
            for match in reversed(list(pattern.finditer(text))):
                begin, end = match.span()
                replacement = rule["replacement"]
                source_span = (mapping[begin][0], mapping[end-1][1])
                text = text[:begin] + replacement + text[end:]
                mapping[begin:end] = [source_span] * len(replacement)
    return text, mapping

def word_timings(result, spoken_text, mapping, source_offset, audio_offset, duration):
    """Accept real model token durations only when every word maps monotonically."""
    if not result or not result.get("words"): return None
    output, position, previous_end = [], 0, 0.0
    for word in result["words"]:
        token = word["text"].strip()
        found = spoken_text.find(token, position)
        if found < 0 or not (0 <= word["start"] <= word["end"] <= duration + .05) or word["start"] < previous_end - .05:
            return None
        finish = found + len(token)
        output.append({"start": audio_offset + word["start"], "end": audio_offset + min(duration, word["end"]),
                       "start_offset": source_offset + mapping[found][0], "end_offset": source_offset + mapping[finish-1][1]})
        position, previous_end = finish, word["end"]
    return output or None

def validate_wav(path):
    with wave.open(str(path), "rb") as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getframerate() != 24000 or audio.getnframes() < 240:
            raise ValueError("Engine produced invalid or empty audio")
        return audio.getnframes() / audio.getframerate()

class Worker:
    def __init__(self, store, engines, config):
        self.store, self.engines, self.config = store, engines, config
        self.stop = threading.Event()
        self.wake = threading.Event()
        self.thread = None

    def start(self):
        with self.store.db() as db:
            for row in db.execute("SELECT id,data FROM jobs").fetchall():
                job = json.loads(row["data"])
                if job["status"] == "running":
                    job["status"] = "queued"
                    job["error"] = "Recovered after companion restart"
                    db.execute("UPDATE jobs SET data=? WHERE id=?", (canonical(job), row["id"]))
        self.thread = threading.Thread(target=self.loop, daemon=True, name="bookpocket-worker")
        self.thread.start()

    def close(self):
        self.stop.set()
        self.wake.set()
        if self.thread: self.thread.join(timeout=3)
        for engine in self.engines.values():
            if hasattr(engine, "close"): engine.close()

    def loop(self):
        while not self.stop.is_set():
            queued = [j for j in reversed(self.store.all("jobs")) if j["status"] == "queued"]
            if queued:
                self.run(queued[0]["id"])
            else:
                self.wake.wait(1)
                self.wake.clear()

    def update(self, job_id, modify, expected=None):
        with self.store.db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT data FROM jobs WHERE id=?", (job_id,)).fetchone()
            if not row: return None
            job = json.loads(row[0])
            if expected and job["status"] not in expected: return None
            modify(job)
            db.execute("UPDATE jobs SET data=? WHERE id=?", (canonical(job), job_id))
            return job

    def active(self, job_id):
        row = self.store.item("jobs", job_id)
        return not self.stop.is_set() and row and json.loads(row["data"])["status"] == "running"

    def voice(self, engine, voice_id):
        row = self.store.item("voices", voice_id)
        if row:
            return {**json.loads(row["data"]), "reference": row["reference"], "transcript": row["transcript"]}
        return next((v for v in engine.voices() if v["id"] == voice_id), None)

    def run(self, job_id):
        def begin(j):
            j.update(status="running", started_at=j.get("started_at") or now(), error=None)
        job = self.update(job_id, begin, {"queued"})
        if not job: return
        try:
            request = json.loads(self.store.item("jobs", job_id)["request"])
            book = json.loads(self.store.item("books", request["book_id"])["data"])
            segment_map = {s["id"]: (s, c, i) for c in book["chapters"] for i, s in enumerate(c["segments"])}
            engine = self.engines[request["engine"]]
            for other in self.engines.values():
                if other is not engine and hasattr(other, "close"): other.close()
            if not engine.info()["available"]: raise RuntimeError(engine.info()["reason"])
            for segment_id in request["segment_ids"]:
                if not self.active(job_id): return
                segment, chapter, index = segment_map[segment_id]
                voice_id = request.get("cast", {}).get(segment_id, request["voice_id"])
                voice = self.voice(engine, voice_id)
                if not voice: raise RuntimeError("Selected voice no longer exists")
                span_plan = sorted([p for p in request.get("narration_plan", []) if p["segment_id"] == segment_id], key=lambda p: p["start_offset"])
                voice_revisions = {}
                for span_voice in {voice_id, *(p["voice_id"] for p in span_plan)}:
                    selected = self.voice(engine, span_voice)
                    if not selected: raise RuntimeError("A cast voice no longer exists")
                    voice_revisions[span_voice] = {"reference": digest(Path(selected["reference"]).read_bytes()) if selected.get("reference") else None, "transcript": selected.get("transcript")}
                announce = chapter["title"] if request["announce_chapters"] and index == 0 and segment["text"] != chapter["title"] else None
                key = digest(canonical({"segment": segment_id, "engine": engine.id, "version": engine.version,
                                        "voice": voice_id, "voice_revision": digest(Path(voice["reference"]).read_bytes()) if voice.get("reference") else (request["request_id"] if engine.id == "voicestudio" else engine.version),
                                        "transcript": voice.get("transcript"), "narration_plan": span_plan, "voice_revisions": voice_revisions,
                                        "rules": request["pronunciation_rules"], "language": request["language"], "announce": announce}))
                with self.store.db() as db:
                    cached = db.execute("SELECT data,path FROM assets WHERE cache_key=?", (key,)).fetchone()
                started = time.monotonic()
                asset = None
                if cached:
                    path = Path(cached["path"])
                    metadata = json.loads(cached["data"])
                    if path.exists() and digest(path.read_bytes()) == metadata["sha256"]:
                        validate_wav(path)
                        asset = metadata
                if not asset:
                    asset = self.render(engine, voice, segment, request, announce, key, job_id)
                if not asset or not self.active(job_id): return
                elapsed = time.monotonic() - started
                def complete_segment(j):
                    j["assets"] = [a for a in j["assets"] if a["segment_id"] != segment_id] + [asset]
                    order = {sid: i for i, sid in enumerate(j["segment_ids"])}
                    j["assets"].sort(key=lambda a: order[a["segment_id"]])
                    j["completed_segments"] = len(j["assets"])
                    j["generation_seconds"] += elapsed
                self.update(job_id, complete_segment, {"running"})
            self.update(job_id, lambda j: j.update(status="completed", finished_at=now()), {"running"})
        except Exception as exc:
            self.update(job_id, lambda j: j.update(status="failed", finished_at=now(), error=str(exc)[:2000]), {"running"})

    def render(self, engine, voice, segment, request, announce, key, job_id):
        with tempfile.TemporaryDirectory(dir=self.store.root / "assets") as temporary:
            temp = Path(temporary)
            final = temp / "joined.wav"
            timings, cursor, word_aligned = [], 0.0, True
            parts = [(None, None, announce, voice)] if announce else []
            plans = sorted([p for p in request.get("narration_plan", []) if p["segment_id"] == segment["id"]], key=lambda p: p["start_offset"])
            ranges, position = [], 0
            for plan in plans:
                if plan["start_offset"] > position: ranges.append((position, plan["start_offset"], voice))
                ranges.append((plan["start_offset"], plan["end_offset"], self.voice(engine, plan["voice_id"])))
                position = plan["end_offset"]
            if position < len(segment["text"]): ranges.append((position, len(segment["text"]), voice))
            for begin, finish, selected_voice in ranges:
                for start, end, text in sentences(segment["text"][begin:finish]):
                    parts.append((begin + start, begin + end, text, selected_voice))
            with wave.open(str(final), "wb") as joined:
                joined.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
                for index, (start, end, text, selected_voice) in enumerate(parts):
                    if not self.active(job_id): return None
                    raw, normalized = temp / f"{index}-raw.wav", temp / f"{index}.wav"
                    spoken_text, mapping = spoken_mapping(text, request["pronunciation_rules"])
                    if not spoken_text.strip(): raise ValueError("Pronunciation rules removed an entire spoken passage")
                    result = engine.synthesize(spoken_text, selected_voice, raw, request["language"])
                    subprocess.run([self.config.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(raw), "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", str(normalized)], check=True, capture_output=True, timeout=120)
                    duration = validate_wav(normalized)
                    with wave.open(str(normalized), "rb") as wav: joined.writeframes(wav.readframes(wav.getnframes()))
                    if start is not None:
                        words = word_timings(result, spoken_text, mapping, start, cursor, duration)
                        if words: timings.extend(words)
                        else:
                            word_aligned = False
                            timings.append({"start": cursor, "end": cursor + duration, "start_offset": start, "end_offset": end})
                    cursor += duration
                    if start is None:
                        joined.writeframes(b"\0" * 24000)  # half-second chapter announcement pause
                        cursor += .5
            validate_wav(final)
            content_hash = digest(final.read_bytes())
            asset_id = str(uuid.uuid4())
            destination = self.store.root / "assets" / (asset_id + ".wav")
            asset = {"id": asset_id, "segment_id": segment["id"], "media_type": "audio/wav", "duration": cursor,
                     "sha256": content_hash, "bytes": final.stat().st_size, "url": "/v1/assets/" + asset_id,
                     "timings": timings, "alignment": "word" if word_aligned else "sentence", "source_start": 0, "source_end": len(segment["text"]), "cast_spans": plans}
            if not self.active(job_id): return None
            final.replace(destination)
            with self.store.db() as db:
                db.execute("INSERT OR REPLACE INTO assets(id,cache_key,data,path) VALUES(?,?,?,?)", (asset_id, key, canonical(asset), str(destination)))
            return asset
