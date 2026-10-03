"""Portable audiobook project import. No archive paths are extracted."""
import json
from pathlib import Path, PurePosixPath
import uuid
import zipfile
from .publication import parse_book
from .store import canonical, digest, now
from .worker import validate_wav
from .casting import Cast, validate_cast
from .archiveio import stream_for, file_digest, copy_member, require_disk, MAX_EXPANDED, MAX_ASSET
from .models import validate_source_ranges, validate_narration_plan, narration_mode, job_metadata


def import_project(store, content):
    content = stream_for(content)
    import_key = "project:" + file_digest(content)
    with store.db() as db:
        existing = db.execute("SELECT data,request FROM jobs WHERE request_id=?", (import_key,)).fetchone()
        if existing:
            job = json.loads(existing[0])
            book = json.loads(store.item("books", job["book_id"])["data"])
            generation = json.loads(existing["request"])
            job = job_metadata(job, generation)
            unresolved = db.execute("SELECT value FROM preferences WHERE key=?", ("unresolved_voices:" + job["id"],)).fetchone()
            return {"book": book, "job": job, "cast": generation.get("imported_cast", {"characters": [], "assignments": []}), "unresolved_voices": json.loads(unresolved[0]) if unresolved else []}
    staged = []
    try:
        with zipfile.ZipFile(content) as archive:
            members = archive.infolist()
            names = [m.filename for m in members]
            expanded = sum(m.file_size for m in members)
            if len(names) != len(set(names)) or len(names) > 100000 or expanded > MAX_EXPANDED:
                raise ValueError("Project archive exceeds safe size limits or contains duplicate entries")
            require_disk(store.root, expanded)
            for item in members:
                if item.filename.startswith(("/", "\\")) or "\\" in item.filename or ":" in item.filename or ".." in PurePosixPath(item.filename).parts or item.flag_bits & 1:
                    raise ValueError("Unsafe project archive path")
            if archive.getinfo("project.json").file_size > 20 * 1024 * 1024: raise ValueError("Project manifest is too large")
            manifest = json.loads(archive.read("project.json"))
            if manifest.get("format_version") != 1: raise ValueError("Unsupported project format version")
            source_name = "source.epub" if "source.epub" in names else "source.txt"
            if archive.getinfo(source_name).file_size > 100 * 1024 * 1024: raise ValueError("Original publication exceeds 100 MiB")
            source = archive.read(source_name)
            book = parse_book(source, manifest.get("book", {}).get("title", "Imported book") + Path(source_name).suffix)
            if book["source_sha256"] != manifest["book"]["source_sha256"]: raise ValueError("Original publication checksum does not match the project")
            segments = {s["id"]: s for c in book["chapters"] for s in c["segments"]}
            original_job = manifest["job"]
            selected = original_job["segment_ids"]
            if not selected or len(set(selected)) != len(selected) or not set(selected) <= segments.keys():
                raise ValueError("Project contains unknown or duplicate source spans")
            generation = manifest.get("generation", {})
            if not isinstance(generation, dict): raise ValueError("Project generation must be an object")
            mode = narration_mode(generation)
            if narration_mode(original_job, mode) != mode: raise ValueError("Project job and generation narration modes disagree")
            for field in ("cast", "narration_plan"):
                if field in original_job and original_job[field] != generation.get(field, {} if field == "cast" else []):
                    raise ValueError("Project job and generation cast metadata disagree")
            source_ranges = generation.get("source_ranges", [])
            validate_source_ranges(source_ranges, selected, {sid: len(s["text"]) for sid, s in segments.items()})
            if original_job.get("source_ranges", source_ranges) != source_ranges:
                raise ValueError("Project job and generation source ranges disagree")
            if source_ranges and (generation.get("cast") or generation.get("announce_chapters")):
                raise ValueError("Partial source projects cannot use whole-segment cast overrides or chapter announcements")
            validate_narration_plan(generation.get("narration_plan", []), selected, {sid: len(s["text"]) for sid, s in segments.items()}, source_ranges)
            source_by_segment = {value["segment_id"]: value for value in source_ranges}
            assets = []
            for asset in original_job["assets"]:
                if asset["segment_id"] not in selected: raise ValueError("Audio points outside the selected source spans")
                if narration_mode(asset, mode) != mode: raise ValueError("Project audio and generation narration modes disagree")
                expected_plan = sorted([span for span in generation.get("narration_plan", []) if span["segment_id"] == asset["segment_id"]], key=lambda span: span["start_offset"])
                if asset.get("cast_spans", expected_plan) != expected_plan: raise ValueError("Project audio cast spans do not match its generation plan")
                scope = source_by_segment.get(asset["segment_id"])
                source_start = scope["start_offset"] if scope else 0
                source_end = scope["end_offset"] if scope else len(segments[asset["segment_id"]]["text"])
                if asset.get("source_start", source_start) != source_start or asset.get("source_end", source_end) != source_end:
                    raise ValueError("Project audio scope does not match the requested source range")
                asset_id = str(uuid.uuid4())
                path = store.root / "assets" / (asset_id + ".wav")
                staged.append(path)
                size, checksum = copy_member(archive, "audio/" + asset["id"] + ".wav", path, MAX_ASSET)
                if checksum != asset["sha256"]: raise ValueError("Project audio failed checksum validation")
                duration = validate_wav(path)
                previous = 0.0
                for timing in asset.get("timings", []):
                    if not (0 <= timing["start"] <= timing["end"] <= duration + .05 and timing["start"] >= previous - .05
                            and source_start <= timing["start_offset"] < timing["end_offset"] <= source_end):
                        raise ValueError("Project timings fall outside the original text or audio")
                    previous = timing["end"]
                metadata = {**asset, "id": asset_id, "duration": duration, "bytes": size, "url": "/v1/assets/" + asset_id,
                            "source_start": source_start, "source_end": source_end, "narration_mode": mode, "cast_spans": expected_plan}
                assets.append((metadata, path))
            if len(assets) != len(selected) or {a[0]["segment_id"] for a in assets} != set(selected):
                raise ValueError("Project is missing required recordings")
            order = {sid: i for i, sid in enumerate(selected)}
            assets.sort(key=lambda a: order[a[0]["segment_id"]])
            book_path = store.root / "books" / (book["id"] + Path(source_name).suffix)
            if not book_path.exists():
                source_temp = book_path.with_suffix(book_path.suffix + "." + str(uuid.uuid4()) + ".tmp")
                source_temp.write_bytes(source)
                source_temp.replace(book_path)
            job = {**original_job, "id": str(uuid.uuid4()), "book_id": book["id"], "status": "completed", "assets": [a[0] for a in assets],
                   "completed_segments": len(selected), "total_segments": len(selected), "error": None, "imported_at": now()}
            if not job.get("voice_name"):
                job["voice_name"] = next((v.get("name") for v in manifest.get("voices", []) if v.get("id") == job.get("voice_id")), None)
            if source_ranges: job["source_ranges"] = source_ranges
            generation["request_id"] = import_key
            generation["narration_mode"] = mode
            voices, voice_map, unresolved = [], {}, []
            for voice in manifest.get("voices", []):
                previous_id = voice["id"]
                if voice.get("reference_included"):
                    if archive.getinfo(voice["reference"]).file_size > 20 * 1024**2: raise ValueError("Voice reference exceeds 20 MiB")
                    audio = archive.read(voice["reference"])
                    if digest(audio) != voice["reference_sha256"]: raise ValueError("Voice reference checksum mismatch")
                    new_id = str(uuid.uuid4())
                    reference = store.root / "voices" / (new_id + ".wav")
                    reference.write_bytes(audio); staged.append(reference)
                    duration = validate_wav(reference)
                    if not 3 <= duration <= 120: raise ValueError("Voice references must contain 3–120 seconds")
                    metadata = {key: voice[key] for key in ("name", "engine", "kind", "language")}
                    metadata.update(id=new_id, created_at=now())
                    voice_map[previous_id] = new_id
                    voices.append((new_id, canonical(metadata), str(reference), voice.get("transcript", "")))
                elif not store.item("voices", previous_id) and not previous_id.startswith("kokoro:"):
                    unresolved.append({**voice, "requires_reassignment": True})
            imported_cast = Cast.model_validate(manifest.get("cast", {"characters": [], "assignments": []}))
            for character in imported_cast.characters:
                if character.voice_id in voice_map: character.voice_id = voice_map[character.voice_id]
            validate_cast(imported_cast, book)
            if generation.get("voice_id") in voice_map: generation["voice_id"] = voice_map[generation["voice_id"]]
            generation["cast"] = {key: voice_map.get(value, value) for key, value in generation.get("cast", {}).items()}
            for span in generation.get("narration_plan", []): span["voice_id"] = voice_map.get(span["voice_id"], span["voice_id"])
            generation["imported_cast"] = imported_cast.model_dump()
            job["voice_id"] = voice_map.get(job["voice_id"], job["voice_id"])
            for asset, _ in assets:
                for span in asset.get("cast_spans", []): span["voice_id"] = voice_map.get(span["voice_id"], span["voice_id"])
            job = job_metadata(job, generation)
            with store.db() as db:
                db.execute("BEGIN IMMEDIATE")
                db.execute("INSERT OR IGNORE INTO books VALUES(?,?,?)", (book["id"], canonical(book), str(book_path)))
                for asset, path in assets: db.execute("INSERT INTO assets VALUES(?,?,?,?)", (asset["id"], None, canonical(asset), str(path)))
                db.executemany("INSERT INTO voices VALUES(?,?,?,?)", voices)
                # Preserve an existing library cast; the imported cast remains in this job's metadata.
                db.execute("INSERT OR IGNORE INTO casts VALUES(?,?)", (book["id"], canonical(imported_cast.model_dump())))
                db.execute("INSERT OR REPLACE INTO preferences VALUES(?,?)", ("unresolved_voices:" + job["id"], canonical(unresolved)))
                db.execute("INSERT INTO jobs VALUES(?,?,?,?)", (job["id"], import_key, canonical(generation), canonical(job)))
            staged.clear()
            return {"book": book, "job": job, "cast": imported_cast.model_dump(), "unresolved_voices": unresolved}
    finally:
        for path in staged: path.unlink(missing_ok=True)
