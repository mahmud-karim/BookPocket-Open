"""Read-only timing audit for one explicitly selected isolated endurance run.

This observes durable SQLite metadata, never modifies the running companion,
and does not establish physical-device highlighting or speech quality.
"""
import argparse
from contextlib import closing
import json
import math
from pathlib import Path
import sqlite3
import time


def validate_timing(segment, asset):
    text = segment["text"]
    duration = asset["duration"]
    assert math.isfinite(duration) and duration > 0, "Invalid asset duration"
    assert (asset["source_start"], asset["source_end"]) == (0, len(text)), "Unexpected source scope"
    assert asset["alignment"] in {"word", "sentence"}, "Unknown alignment precision"
    assert asset["timings"], "Missing timing metadata"
    covered = bytearray(len(text))
    previous_audio_end = 0.0
    previous_source_end = 0
    for timing in asset["timings"]:
        start, end = timing["start"], timing["end"]
        first, last = timing["start_offset"], timing["end_offset"]
        assert math.isfinite(start) and math.isfinite(end), "Nonfinite audio timing"
        assert 0 <= start <= end <= duration + .000001, "Timing outside audio"
        # Production's real token validator permits up to 50 ms token overlap.
        assert start >= previous_audio_end - .05, "Nonmonotonic audio timing"
        assert isinstance(first, int) and isinstance(last, int), "Nonscalar offset"
        assert previous_source_end <= first < last <= len(text), "Nonmonotonic source timing"
        covered[first:last] = b"\x01" * (last - first)
        previous_audio_end, previous_source_end = end, last
    missing = [index for index, character in enumerate(text) if character.isalnum() and not covered[index]]
    assert not missing, f"Uncovered source letters or numbers: {len(missing)}"


def audit(root, report, minutes):
    root = root.resolve(strict=True)
    allowed = Path(__file__).resolve().parent.parent / "artifacts"
    assert root.parent == allowed.resolve(strict=True), "Expected ignored artifacts directory"
    assert root.name.startswith("bookpocket-cpu-endurance-") and not root.is_symlink(), "Expected isolated run"
    database = root / "library.sqlite3"
    deadline = time.monotonic() + minutes * 60
    seen, alignments = set(), {"word": 0, "sentence": 0}
    result = {"status": "incomplete", "scope": "durable timing metadata of explicitly selected isolated original-prose CPU run", "physical_iphone_highlighting": "NOT RUN", "literary_voice_quality": "NOT EVALUATED"}
    try:
        while True:
            # mode=ro prevents creating a new database if the selected run exits.
            with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=10)) as connection:
                rows = connection.execute("SELECT data FROM books").fetchall()
                assert len(rows) == 1, "Expected one isolated book"
                book = json.loads(rows[0][0])
                segments = {s["id"]: s for c in book["chapters"] for s in c["segments"]}
                rows = connection.execute("SELECT data FROM jobs").fetchall()
                assert len(rows) == 1, "Expected one isolated render job"
                job = json.loads(rows[0][0])
            assert job["segment_ids"] == list(segments), "Unexpected source order"
            for asset in job["assets"]:
                if asset["id"] in seen:
                    continue
                assert asset["segment_id"] in segments, "Foreign source segment"
                validate_timing(segments[asset["segment_id"]], asset)
                seen.add(asset["id"])
                alignments[asset["alignment"]] += 1
            result.update(validated_assets=len(seen), expected_assets=len(segments), alignment_counts=alignments)
            if job["status"] == "completed":
                assert len(seen) == len(segments) == len(job["assets"]), "Incomplete durable assets"
                assert [a["segment_id"] for a in job["assets"]] == job["segment_ids"], "Duplicate or unordered source assets"
                result.update(status="pass", finite_in_duration_audio_times="pass", ordered_audio_times_with_50ms_token_overlap="pass", monotonic_scalar_ranges="pass", all_source_letters_and_numbers_covered="pass")
                break
            assert job["status"] not in {"failed", "cancelled"}, "Observed render terminated before completion"
            assert time.monotonic() < deadline, "Timing observation exceeded its deadline"
            time.sleep(10)
    except BaseException as error:
        result.update(error_type=type(error).__name__, error=str(error))
        raise
    finally:
        report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--minutes", type=int, default=240)
    args = parser.parse_args()
    if not 1 <= args.minutes <= 240:
        parser.error("Use an observation deadline from 1 through 240 minutes")
    audit(args.root, args.report, args.minutes)
