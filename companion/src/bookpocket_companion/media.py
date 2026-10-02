import json
from pathlib import Path
import subprocess
import tempfile
import uuid
import wave
import zipfile
from .store import canonical, digest


def normalize_reference(content, path, ffmpeg):
    with tempfile.TemporaryDirectory(dir=path.parent) as temporary:
        source = Path(temporary) / "reference"
        source.write_bytes(content)
        output = Path(temporary) / "normalized.wav"
        result = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-protocol_whitelist", "file,pipe", "-format_whitelist", "wav,mp3,flac,ogg,mov,aac,aiff", "-i", str(source), "-t", "121", "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", str(output)], capture_output=True, timeout=60)
        if result.returncode: raise ValueError("Choose a decodable audio recording")
        with wave.open(str(output), "rb") as audio:
            duration = audio.getnframes() / audio.getframerate()
        if not 3 <= duration <= 120: raise ValueError("Voice references must be between 3 and 120 seconds")
        output.replace(path)


def export_job(store, job, format, ffmpeg):
    book_row = store.item("books", job["book_id"])
    if not book_row: raise ValueError("The original book has been deleted")
    book = json.loads(book_row["data"])
    request = json.loads(store.item("jobs", job["id"])["request"])
    identity = str(uuid.uuid4())
    extension = ".zip" if format == "project" else "." + format
    destination = store.root / "exports" / (identity + extension)
    with tempfile.TemporaryDirectory(dir=store.root / "exports") as temporary:
        temp = Path(temporary)
        output = temp / ("audiobook" + extension)
        assets = [store.item("assets", a["id"]) for a in job["assets"]]
        if any(not a or not Path(a["path"]).exists() for a in assets): raise ValueError("A required audio segment is missing")
        for a in assets:
            if digest(Path(a["path"]).read_bytes()) != json.loads(a["data"])["sha256"]: raise ValueError("A required audio segment failed its checksum")
        if format == "project":
            with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("project.json", canonical({"format_version": 1, "book": book, "job": job, "generation": request}))
                archive.write(book_row["source"], "source" + Path(book_row["source"]).suffix)
                for a in assets: archive.write(a["path"], "audio/" + a["id"] + ".wav")
        else:
            # Build one stream instead of trusting arbitrary concat paths or loading the book in RAM.
            joined = temp / "joined.wav"
            with wave.open(str(joined), "wb") as writer:
                writer.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
                for a in assets:
                    with wave.open(a["path"], "rb") as reader:
                        while chunk := reader.readframes(24000 * 10): writer.writeframes(chunk)
            def escape(value): return str(value).replace("\\", "\\\\").replace("=", "\\=").replace(";", "\\;").replace("#", "\\#").replace("\n", " ")
            metadata = [";FFMETADATA1", "title="+escape(book["title"]), "artist="+escape(book["author"])]
            chapter_by_segment = {s["id"]: c for c in book["chapters"] for s in c["segments"]}
            groups, cursor = [], 0
            for asset in job["assets"]:
                chapter = chapter_by_segment[asset["segment_id"]]
                end = cursor + round(asset["duration"] * 1000)
                if groups and groups[-1][0] == chapter["id"]: groups[-1][3] = end
                else: groups.append([chapter["id"], chapter["title"], cursor, end])
                cursor = end
            for _, title, start, end in groups:
                metadata += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={start}", f"END={end}", "title="+escape(title)]
            meta_file = temp / "chapters.txt"
            meta_file.write_text("\n".join(metadata), encoding="utf-8")
            codec = ["-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart"] if format == "m4b" else ["-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", "3"]
            subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(joined), "-i", str(meta_file), "-map_metadata", "1", "-map_chapters", "1", *codec, str(output)], check=True, capture_output=True, timeout=3600)
        output.replace(destination)
    media_type = {"project": "application/zip", "m4b": "audio/mp4", "mp3": "audio/mpeg"}[format]
    asset = {"id": identity, "segment_id": None, "media_type": media_type, "duration": sum(a["duration"] for a in job["assets"]),
             "sha256": digest(destination.read_bytes()), "bytes": destination.stat().st_size, "url": "/v1/assets/"+identity, "timings": []}
    with store.db() as db: db.execute("INSERT INTO assets VALUES(?,?,?,?)", (identity, None, canonical(asset), str(destination)))
    return asset
