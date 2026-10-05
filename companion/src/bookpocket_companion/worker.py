import json
import re
import shutil
import subprocess
import threading
import time
import uuid
import wave
from pathlib import Path
from .store import canonical, digest, now
from .models import validate_source_ranges, validate_narration_plan, narration_mode, job_metadata
from .render_workspace import render_workspace, cleanup_abandoned_renders
from .scheduler import WorkScheduler, WorkCancelled, WorkOwnershipUncertain

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

def word_timings(result, spoken_text, mapping, source_offset, audio_offset, duration, require_complete=False):
    """Accept real model token durations only when every word maps monotonically."""
    if not result or not result.get("words"): return None
    output, covered, position, previous_end = [], [], 0, 0.0
    for word in result["words"]:
        token = word["text"].strip()
        found = spoken_text.find(token, position)
        if found < 0 or not (0 <= word["start"] < word["end"] <= duration + .05) or word["start"] < previous_end - .05:
            return None
        finish = found + len(token)
        output.append({"start": audio_offset + word["start"], "end": audio_offset + min(duration, word["end"]),
                       "start_offset": source_offset + mapping[found][0], "end_offset": source_offset + mapping[finish-1][1]})
        position, previous_end = finish, word["end"]
        covered.append((found, finish))
    if require_complete and any(not any(begin <= index < end for begin, end in covered)
                                for match in re.finditer(r"[^\W_]+(?:['’][^\W_]+)*", spoken_text)
                                for index in range(match.start(), match.end())):
        return None
    return output or None

def validate_wav(path):
    with wave.open(str(path), "rb") as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getframerate() != 24000 or audio.getnframes() < 240:
            raise ValueError("Engine produced invalid or empty audio")
        return audio.getnframes() / audio.getframerate()

class Worker:
    def __init__(self, store, engines, config, scheduler=None, aligner=None):
        self.store, self.engines, self.config = store, engines, config
        self.scheduler = scheduler or WorkScheduler()
        self.aligner = aligner
        self.stop = threading.Event()
        self.wake = threading.Event()
        self.thread = None

    def start(self):
        cleanup_abandoned_renders(self.store)
        self.store.cleanup_deleted_assets()
        with self.store.db() as db:
            for row in db.execute("SELECT id,data FROM jobs").fetchall():
                job = json.loads(row["data"])
                if job["status"] == "running":
                    job["status"] = "queued"
                    job["error"] = "Recovered after companion restart"
                    db.execute("UPDATE jobs SET data=? WHERE id=?", (canonical(job), row["id"]))
                if job.get("alignment_status") == "running":
                    job.update(alignment_status="queued", alignment_error="Recovered after companion restart")
                    db.execute("UPDATE jobs SET data=? WHERE id=?", (canonical(job), row["id"]))
        self.thread = threading.Thread(target=self.loop, daemon=True, name="bookpocket-worker")
        self.thread.start()

    def close(self):
        self.stop.set()
        self.wake.set()
        for engine in self.engines.values():
            if hasattr(engine, "close"): engine.close()
        if self.aligner: self.aligner.close()
        if self.thread: self.thread.join(timeout=3)

    def loop(self):
        while not self.stop.is_set() and not self.scheduler.stopped.is_set():
            self.store.cleanup_deleted_assets()
            jobs = self.store.all("jobs")
            waiting = [(j['created_at'], 'render', j['id']) for j in jobs if j['status'] == 'queued']
            waiting += [(j.get('alignment_requested_at', j['created_at']), 'alignment', j['id']) for j in jobs if j.get('alignment_status') == 'queued']
            if waiting:
                _, kind, identity = min(waiting)
                if kind == 'render': self.run(identity)
                else: self.run_alignment(identity)
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
        def cancelled():
            row = self.store.item("jobs", job_id)
            return self.stop.is_set() or not row or json.loads(row["data"])["status"] != "queued"
        try:
            with self.scheduler.lease("render", cancelled): self._run(job_id)
        except WorkCancelled:
            return

    def _run(self, job_id):
        def begin(j):
            j.update(status="running", started_at=j.get("started_at") or now(), error=None)
        job = self.update(job_id, begin, {"queued"})
        if not job: return
        try:
            request = json.loads(self.store.item("jobs", job_id)["request"])
            book = json.loads(self.store.item("books", request["book_id"])["data"])
            segment_map = {s["id"]: (s, c, i) for c in book["chapters"] for i, s in enumerate(c["segments"])}
            source_ranges = request.get("source_ranges", [])
            validate_source_ranges(source_ranges, request["segment_ids"], {sid: len(s[0]["text"]) for sid, s in segment_map.items()})
            if source_ranges and (request.get("cast") or request.get("announce_chapters")):
                raise ValueError("Source ranges cannot use whole-segment cast overrides or chapter announcements")
            validate_narration_plan(request.get("narration_plan", []), request["segment_ids"], {sid: len(s[0]["text"]) for sid, s in segment_map.items()}, source_ranges)
            mode = narration_mode(request)
            self.update(job_id, lambda j: j.update(job_metadata(j, request)), {"running"})
            source_by_segment = {value["segment_id"]: value for value in source_ranges}
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
                selected_range = source_by_segment.get(segment_id)
                key = digest(canonical({"segment": segment_id, "engine": engine.id, "version": engine.version,
                                        "voice": voice_id, "voice_revision": digest(Path(voice["reference"]).read_bytes()) if voice.get("reference") else (request["request_id"] if engine.id == "voicestudio" else engine.version),
                                        "transcript": voice.get("transcript"), "narration_plan": span_plan, "voice_revisions": voice_revisions,
                                        "take_id": request.get("take_id"),
                                        **({"narration_mode": mode} if mode == "full_cast" and not span_plan and segment_id not in request.get("cast", {}) else {}),
                                        **({"source_range": selected_range} if selected_range else {}),
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
                        asset = {**metadata, "narration_mode": mode}
                if not asset:
                    asset = self.render(engine, voice, segment, request, announce, key, job_id, selected_range)
                if not asset or not self.active(job_id): return
                elapsed = time.monotonic() - started
                def complete_segment(j):
                    # Deletion can remove a cached artifact between its initial
                    # verification and publication into another running job.
                    if not self.store.item("assets", asset["id"]): raise ValueError("The selected cached audio was deleted; retry generation")
                    j["assets"] = [a for a in j["assets"] if a["segment_id"] != segment_id] + [asset]
                    order = {sid: i for i, sid in enumerate(j["segment_ids"])}
                    j["assets"].sort(key=lambda a: order[a["segment_id"]])
                    j["completed_segments"] = len(j["assets"])
                    j["generation_seconds"] += elapsed
                self.update(job_id, complete_segment, {"running"})
            self.update(job_id, lambda j: j.update(status="completed", finished_at=now()), {"running"})
        except Exception as exc:
            self.update(job_id, lambda j: j.update(status="failed", finished_at=now(), error=str(exc)[:2000]), {"running"})
            if isinstance(exc, WorkOwnershipUncertain): raise

    def render(self, engine, voice, segment, request, announce, key, job_id, selected_range=None):
        with render_workspace(self.store, job_id, segment["id"]) as temp:
            final = temp / "joined.wav"
            timings, source_timings, cursor, word_aligned, alignment_error = [], [], 0.0, True, None
            parts = [(None, None, announce, voice)] if announce else []
            plans = sorted([p for p in request.get("narration_plan", []) if p["segment_id"] == segment["id"]], key=lambda p: p["start_offset"])
            source_start = selected_range["start_offset"] if selected_range else 0
            source_end = selected_range["end_offset"] if selected_range else len(segment["text"])
            ranges, position = [], source_start
            for plan in plans:
                if plan["start_offset"] > position: ranges.append((position, plan["start_offset"], voice))
                ranges.append((plan["start_offset"], plan["end_offset"], self.voice(engine, plan["voice_id"])))
                position = plan["end_offset"]
            if position < source_end: ranges.append((position, source_end, voice))
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
                        source_timings.append({"start": cursor, "end": cursor + duration, "start_offset": start, "end_offset": end})
                        words = word_timings(result, spoken_text, mapping, start, cursor, duration, require_complete=True)
                        if not words and self.aligner and self.aligner.ready() and request["language"] == "en":
                            try:
                                aligned = self.aligner.align(normalized, spoken_text, request["language"])
                                words = word_timings(aligned, spoken_text, mapping, start, cursor, duration, require_complete=True)
                            except Exception as exc:
                                if isinstance(exc, WorkOwnershipUncertain): raise
                                # Generation remains usable; precise highlighting
                                # requires explicit repair rather than fake times.
                                alignment_error = str(exc)[:1000]
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
                     "timings": timings, "source_timings": source_timings, "alignment": "word" if word_aligned else "sentence", "source_start": source_start, "source_end": source_end, "cast_spans": plans,
                     "narration_mode": narration_mode(request)}
            if alignment_error: asset["alignment_error"] = alignment_error
            if not self.active(job_id): return None
            with self.store.db() as db:
                db.execute("BEGIN IMMEDIATE")
                row = db.execute("SELECT data FROM jobs WHERE id=?", (job_id,)).fetchone()
                if not row or json.loads(row[0])["status"] != "running": return None
                final.replace(destination)
                # A damaged prior cache entry may still be referenced by an
                # older take; invalidate its cache key without erasing its ID.
                db.execute("UPDATE assets SET cache_key=NULL WHERE cache_key=?", (key,))
                db.execute("INSERT INTO assets(id,cache_key,data,path) VALUES(?,?,?,?)", (asset_id, key, canonical(asset), str(destination)))
                # Attach in the same transaction as publication, so deletion
                # cannot miss a just-created recording during model completion.
                current = json.loads(row[0])
                current["assets"] = [a for a in current["assets"] if a["segment_id"] != segment["id"]] + [asset]
                db.execute("UPDATE jobs SET data=? WHERE id=?", (canonical(current), job_id))
            return asset

    def run_alignment(self, job_id):
        def queued():
            row = self.store.item("jobs", job_id)
            return self.stop.is_set() or not row or json.loads(row["data"]).get("alignment_status") != "queued"
        try:
            with self.scheduler.lease("alignment", queued): self._align_job(job_id)
        except WorkCancelled: return

    def _align_job(self, job_id):
        def start(job):
            if job.get("alignment_status") != "queued": raise WorkCancelled("Alignment no longer queued")
            job.update(alignment_status="running", alignment_error=None)
        try:
            job = self.update(job_id, start)
            if not job: return
            if not self.aligner: raise RuntimeError("English word alignment is unavailable")
            if not self.aligner.ready(): self.aligner.install(cancel_event=self.stop)
            row = self.store.item("jobs", job_id)
            if not row: return
            request = json.loads(row["request"])
            book = json.loads(self.store.item("books", job["book_id"])["data"])
            segments = {s["id"]: s for c in book["chapters"] for s in c["segments"]}
            repaired = {}
            for asset in job["assets"]:
                if asset.get("alignment") == "word": continue
                row = self.store.item("assets", asset["id"])
                if not row: raise ValueError("Saved audio was deleted")
                path = Path(row["path"])
                if not path.is_file() or digest(path.read_bytes()) != asset["sha256"]: raise ValueError("Saved audio is missing or damaged; generate a new recording")
                text = segments[asset["segment_id"]]["text"]
                timings = asset.get("source_timings") or asset.get("timings", [])
                if not timings: raise ValueError("This older recording has no exact source boundaries; generate a new recording")
                precise = []
                for timing in timings:
                    row = self.store.item("jobs", job_id)
                    if not row or self.stop.is_set(): return
                    start, end = timing["start_offset"], timing["end_offset"]
                    if (type(start) is not int or type(end) is not int or not 0 <= start < end <= len(text)
                            or not 0 <= timing["start"] < timing["end"] <= asset["duration"] + .05):
                        raise ValueError("The recording timing window falls outside its original source or audio")
                    spoken_text, mapping = spoken_mapping(text[start:end], request.get("pronunciation_rules", []))
                    result = self.aligner.align(path, spoken_text, request.get("language", "en"), timing["start"], timing["end"])
                    words = word_timings(result, spoken_text, mapping, start, timing["start"], timing["end"] - timing["start"], require_complete=True)
                    if not words: raise ValueError("Word timings could not be mapped to the original text")
                    precise.extend(words)
                repaired[asset["id"]] = {**asset, "timings": precise, "source_timings": timings,
                                         "alignment": "word", "alignment_method": "ctc-acoustic-v1"}
                repaired[asset["id"]].pop("alignment_error", None)
            with self.store.db() as db:
                db.execute("BEGIN IMMEDIATE")
                if not db.execute("SELECT 1 FROM jobs WHERE id=?", (job_id,)).fetchone(): return
                # An asset ID always has one canonical timing track, including
                # other saved takes that reused this exact immutable waveform.
                for identity, asset in repaired.items():
                    if not db.execute("SELECT 1 FROM assets WHERE id=?", (identity,)).fetchone(): raise ValueError("Saved audio was deleted during alignment")
                    db.execute("UPDATE assets SET data=? WHERE id=?", (canonical(asset), identity))
                for row in db.execute("SELECT id,data FROM jobs").fetchall():
                    value = json.loads(row["data"])
                    affected = any(a["id"] in repaired for a in value["assets"])
                    if affected: value["assets"] = [repaired.get(a["id"], a) for a in value["assets"]]
                    if row["id"] == job_id: value.update(alignment_status="completed", alignment_error=None)
                    if affected or row["id"] == job_id: db.execute("UPDATE jobs SET data=? WHERE id=?", (canonical(value), row["id"]))
        except WorkCancelled: return
        except Exception as exc:
            self.update(job_id, lambda j: j.update(alignment_status="failed", alignment_error=str(exc)[:1500]))
            if isinstance(exc, WorkOwnershipUncertain): raise
