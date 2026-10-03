import json
from pathlib import Path
import subprocess
import tempfile
import uuid
import wave
import zipfile
from .store import canonical
from .archiveio import file_digest, require_disk
from .models import narration_mode, job_metadata


def normalize_reference(content, path, ffmpeg, trim_start=0.0, trim_end=None):
    if trim_start < 0 or (trim_end is not None and trim_end <= trim_start):
        raise ValueError("Choose a valid reference trim range")
    duration_limit = min(121, trim_end - trim_start) if trim_end is not None else 121
    with tempfile.TemporaryDirectory(dir=path.parent) as temporary:
        source = Path(temporary) / "reference"
        source.write_bytes(content)
        output = Path(temporary) / "normalized.wav"
        result = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-protocol_whitelist", "file,pipe", "-format_whitelist", "wav,mp3,flac,ogg,mov,aac,aiff", "-i", str(source), "-ss", str(trim_start), "-t", str(duration_limit), "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", str(output)], capture_output=True, timeout=60)
        if result.returncode: raise ValueError("Choose a decodable audio recording")
        with wave.open(str(output), "rb") as audio:
            duration = audio.getnframes() / audio.getframerate()
        if not 3 <= duration <= 120: raise ValueError("Voice references must be between 3 and 120 seconds")
        output.replace(path)


def export_job(store, job, format, ffmpeg, include_voice_references=False):
    book_row = store.item("books", job["book_id"])
    if not book_row: raise ValueError("The original book has been deleted")
    book = json.loads(book_row["data"])
    request = json.loads(store.item("jobs", job["id"])["request"])
    job = job_metadata(job, request)
    identity = str(uuid.uuid4())
    duration = sum(a["duration"] for a in job["assets"])
    extension = ".zip" if format == "project" else "." + format
    destination = store.root / "exports" / (identity + extension)
    with tempfile.TemporaryDirectory(dir=store.root / "exports") as temporary:
        temp = Path(temporary)
        output = temp / ("audiobook" + extension)
        assets = [store.item("assets", a["id"]) for a in job["assets"]]
        if any(not a or not Path(a["path"]).exists() for a in assets): raise ValueError("A required audio segment is missing")
        require_disk(store.root, 2 * sum(Path(a["path"]).stat().st_size for a in assets) + Path(book_row["source"]).stat().st_size)
        for a in assets:
            if file_digest(Path(a["path"])) != json.loads(a["data"])["sha256"]: raise ValueError("A required audio segment failed its checksum")
        if format == "project":
            with store.db() as db:
                cast_row = db.execute("SELECT data FROM casts WHERE book_id=?", (book["id"],)).fetchone()
            cast = json.loads(cast_row[0]) if cast_row else {"characters": [], "assignments": []}
            voice_ids = {request.get("voice_id"), *request.get("cast", {}).values(), *(p["voice_id"] for p in request.get("narration_plan", [])), *(c.get("voice_id") for c in cast.get("characters", []))} - {None}
            voices, references = [], []
            for voice_id in sorted(voice_ids):
                row = store.item("voices", voice_id)
                metadata = json.loads(row["data"]) if row else {"id": voice_id, "name": voice_id, "engine": job["engine"], "kind": "preset" if voice_id.startswith("kokoro:") else "clone", "language": request.get("language", "en")}
                metadata["reference_included"] = bool(include_voice_references and row and row["reference"] and Path(row["reference"]).exists())
                if metadata["reference_included"]:
                    reference_name = "voices/" + voice_id + ".wav"
                    metadata.update(reference=reference_name, reference_sha256=file_digest(Path(row["reference"])), transcript=row["transcript"])
                    references.append((row["reference"], reference_name))
                voices.append(metadata)
            with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("project.json", canonical({"format_version": 1, "book": book, "job": job, "generation": request, "cast": cast, "voices": voices}))
                archive.write(book_row["source"], "source" + Path(book_row["source"]).suffix)
                for a in assets: archive.write(a["path"], "audio/" + a["id"] + ".wav")
                for path, name in references: archive.write(path, name)
        else:
            # Build one stream instead of trusting arbitrary concat paths or loading the book in RAM.
            joined = temp / "joined.pcm"
            frame_counts = []
            with joined.open("wb") as writer:
                for a in assets:
                    with wave.open(a["path"], "rb") as reader:
                        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, 24000):
                            raise ValueError("Audio must be normalized to mono 24 kHz PCM16")
                        frames = 0
                        while chunk := reader.readframes(24000 * 10):
                            if len(chunk) % 2: raise ValueError("Audio contains an incomplete PCM16 frame")
                            writer.write(chunk)
                            frames += len(chunk) // 2
                        frame_counts.append(frames)
            def escape(value): return str(value).replace("\\", "\\\\").replace("=", "\\=").replace(";", "\\;").replace("#", "\\#").replace("\n", " ")
            metadata = [";FFMETADATA1", "title="+escape(book["title"]), "artist="+escape(book["author"])]
            chapter_by_segment = {s["id"]: c for c in book["chapters"] for s in c["segments"]}
            groups, cursor = [], 0
            for asset, frames in zip(job["assets"], frame_counts):
                chapter = chapter_by_segment[asset["segment_id"]]
                # Keep exact cumulative source frames; per-segment millisecond
                # rounding can move later chapter boundaries by whole seconds.
                end = cursor + frames
                if groups and groups[-1][0] == chapter["id"]: groups[-1][3] = end
                else: groups.append([chapter["id"], chapter["title"], cursor, end])
                cursor = end
            for _, title, start, end in groups:
                metadata += ["[CHAPTER]", "TIMEBASE=1/24000", f"START={start}", f"END={end}", "title="+escape(title)]
            duration = cursor / 24000
            meta_file = temp / "chapters.txt"
            meta_file.write_text("\n".join(metadata), encoding="utf-8")
            codec = ["-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart"] if format == "m4b" else ["-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", "3"]
            subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", str(joined), "-i", str(meta_file), "-map_metadata", "1", "-map_chapters", "1", *codec, str(output)], check=True, capture_output=True, timeout=3600)
        output.replace(destination)
    media_type = {"project": "application/zip", "m4b": "audio/mp4", "mp3": "audio/mpeg"}[format]
    asset = {"id": identity, "segment_id": None, "media_type": media_type, "duration": duration,
             "sha256": file_digest(destination), "bytes": destination.stat().st_size, "url": "/v1/assets/"+identity, "timings": [], "narration_mode": narration_mode(request)}
    with store.db() as db: db.execute("INSERT INTO assets VALUES(?,?,?,?)", (identity, None, canonical(asset), str(destination)))
    return asset
