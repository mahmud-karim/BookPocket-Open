"""Real muxer regression with original test tones, without a speech engine."""
import json
import math
import shutil
import struct
import subprocess
import wave

import pytest

from bookpocket_companion.archiveio import file_digest
from bookpocket_companion.media import export_job
from bookpocket_companion.store import Store, canonical


@pytest.mark.parametrize("format", ["m4b", "mp3"])
def test_export_chapters_follow_pcm_frames_without_accumulated_rounding(tmp_path, format):
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    assert ffmpeg and ffprobe, "Install FFmpeg and FFprobe for media regression tests"
    store = Store(tmp_path / "companion")
    frames, rate, per_chapter = 251, 24000, 300
    tone = struct.pack("<" + "h" * frames, *(int(2000 * math.sin(2 * math.pi * 440 * i / rate)) for i in range(frames)))
    source = store.root / "books" / "original.txt"
    source.write_text("Original test score: three chapters of short, repeated tones.", encoding="utf-8")
    chapters, assets, rows = [], [], []
    for chapter_index in range(3):
        chapter = {"id": f"chapter-{chapter_index}", "title": f"Test movement {chapter_index + 1}", "segments": []}
        for index in range(per_chapter):
            identity = f"tone-{chapter_index}-{index}"
            chapter["segments"].append({"id": identity, "text": "Original test tone."})
            path = store.root / "assets" / (identity + ".wav")
            with wave.open(str(path), "wb") as audio:
                audio.setparams((1, 2, rate, 0, "NONE", "not compressed"))
                audio.writeframes(tone)
            asset = {"id": identity, "segment_id": identity, "duration": frames / rate, "sha256": file_digest(path)}
            assets.append(asset)
            rows.append((identity, None, canonical(asset), str(path)))
        chapters.append(chapter)
    book = {"id": "test-score", "title": "Original tone timing fixture", "author": "Book Pocket tests", "chapters": chapters}
    job = {"id": "test-render", "book_id": book["id"], "assets": assets}
    with store.db() as db:
        db.execute("INSERT INTO books VALUES(?,?,?)", (book["id"], canonical(book), str(source)))
        db.execute("INSERT INTO jobs VALUES(?,?,?,?)", (job["id"], "test-request", "{}", canonical(job)))
        db.executemany("INSERT INTO assets VALUES(?,?,?,?)", rows)

    exported = export_job(store, job, format, ffmpeg)
    path = store.item("assets", exported["id"])["path"]
    report = json.loads(subprocess.check_output([ffprobe, "-v", "error", "-show_chapters", "-of", "json", path]))
    boundaries = [(float(c["start_time"]), float(c["end_time"])) for c in report["chapters"]]
    expected = [(index * per_chapter * frames / rate, (index + 1) * per_chapter * frames / rate) for index in range(3)]
    print(json.dumps({"format": format, "assets": len(assets), "frames_per_asset": frames, "actual_chapters": boundaries, "expected_chapters": expected}))
    subprocess.run([ffmpeg, "-v", "error", "-i", path, "-f", "null", "-"], check=True, capture_output=True)
    assert len(boundaries) == len(expected)
    for actual, intended in zip(boundaries, expected):
        # The muxers can quantize a boundary to milliseconds, but rounding must
        # happen once per boundary, never once per source segment.
        assert actual == pytest.approx(intended, abs=0.001)
    assert exported["duration"] == pytest.approx(len(assets) * frames / rate)
