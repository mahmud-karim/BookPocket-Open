# Public test fixtures

`lantern.epub` contains original short prose written for this repository. `original.txt` contains the same original paragraphs. Both are licensed under Apache-2.0 with the repository.

`test-tone.wav` is a deterministic quiet 440 Hz tone, 250 milliseconds, mono 24 kHz PCM. It contains no human voice and must never be represented as audiobook narration. It exists for media transport, export, and validation tests only.

Regenerate with `python scripts/generate_fixtures.py`. `media-provenance.json` records allowed binary hashes for public-source auditing. Real engine, voice quality, and device tests remain separate gates.
