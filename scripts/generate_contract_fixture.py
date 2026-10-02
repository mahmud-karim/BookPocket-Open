import hashlib
import json
from pathlib import Path

fixtures = Path(__file__).resolve().parents[1] / "tests/fixtures"
source_hash = hashlib.sha256((fixtures / "lantern.epub").read_bytes()).hexdigest()
text = "A compass 🧭 pointed north; café bells sounded beyond the window."
href = "EPUB/chapter1.xhtml"
segment_id = hashlib.sha256(f"{source_hash}\n{href}\n3\n{text}".encode()).hexdigest()
segment = {"id": segment_id, "text": text, "kind": "paragraph", "locator": {"href": href, "type": "application/xhtml+xml", "title": "The Lantern", "locations": {"progression": 0.5}, "text": {"highlight": text}}}
fixture = {"api_version": "1", "purpose": "Wire parsing and Unicode scalar offsets only; not a real generated job", "book": {"id": "contract-book", "title": "The Lantern — Contract Sample", "author": "Book Pocket Contributors", "language": "en", "source_sha256": source_hash, "created_at": "2026-01-01T00:00:00Z", "chapters": [{"id": "chapter-one", "title": "The Lantern", "href": href, "segments": [segment]}]}, "voice": {"id": "contract-voice", "name": "Contract preset", "engine": "contract-only", "kind": "preset", "language": "en", "created_at": "2026-01-01T00:00:00Z"}, "unicode_case": {"text": text, "scalar_start": 10, "scalar_end": 11, "expected_substring": "🧭"}, "job": {"id": "contract-job", "book_id": "contract-book", "status": "completed", "engine": "contract-only", "voice_id": "contract-voice", "segment_ids": [segment_id], "completed_segments": 1, "total_segments": 1, "created_at": "2026-01-01T00:00:00Z", "started_at": "2026-01-01T00:00:01Z", "finished_at": "2026-01-01T00:00:02Z", "generation_seconds": 1.0, "error": None, "assets": [{"id": "contract-asset", "segment_id": segment_id, "media_type": "audio/wav", "duration": 0.25, "sha256": hashlib.sha256((fixtures / "test-tone.wav").read_bytes()).hexdigest(), "bytes": (fixtures / "test-tone.wav").stat().st_size, "url": "/v1/assets/contract-asset", "timings": [{"start": 0.0, "end": 0.25, "start_offset": 10, "end_offset": 11}]}]}}
assert text[10:11] == "🧭"
(fixtures / "contract-v1.json").write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
