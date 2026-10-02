# Verification ledger

Evidence is recorded separately for deterministic tests, real synthesis, simulator checks, and physical hardware. A tone fixture never proves speech quality, model installation, cloning, or audiobook completion.

## Automated acceptance matrix

| Boundary | Required outcome | Evidence / current state |
| --- | --- | --- |
| Public source | No private books, voice references, credentials, personal paths, private endpoints, runtime databases or models | `scripts/public_preflight.py` passed current source on 2026-10-02; rerun before publication |
| Public fixtures | EPUB and PCM bytes reproducible; original prose and media provenance | `tests/test_release_tools.py` passed on Windows, 2026-10-02 |
| IPA artifact | SHA256 match; valid ZIP; one Payload app; iPhoneOS ARM64 executable and embedded frameworks; expected bundle/version; iPad support | `scripts/verify_ipa.py`; rejection tests passed on Windows; real IPA not built |
| API contract | Both clients parse `tests/fixtures/contract-v1.json`; emoji scalar offsets map to exactly the compass character | Python fixture identity/Unicode tests passed; Swift cross-client test pending |
| Offline import | EPUB formatting, chapter order, original source bytes, TXT conversion, malformed/archive traversal rejection | Companion original-byte, chapter order, Unicode and hostile archive tests passed; iOS tests pending |
| Pairing | Wrong/expired/reused code rejected; phone sees pending until local approval; revocation denies access | Pairing approval, exchange retry, expiry, code reuse and revocation tests passed |
| Privacy and transport | Protected media; no bearer token in URLs; LAN certificate pin; loopback admin restriction and same-origin checks | Origin, remote HTTPS/admin restriction and spoofed forwarding tests passed; actual TLS pin/device checks pending |
| Durable generation | Restart recovery, idempotent request reuse, conflict 409, cancellation prevents publication, retries reuse completed segments | Fixture-engine failure/restart/retry/cache corruption/cancellation tests passed; real-book render pending |
| Reader location | Font change, rotation and relaunch preserve source location; pronunciation never edits display text | Simulator tests pending |
| Audio download | Resume interrupted transfer; validate checksum; offline playback and timing/source association | Integration and simulator tests pending |
| Studio | Import, voice creation, job controls, pairing decisions, exports, cast correction, empty/error states | Production build and browser tests pending |
| Full cast | Exact source IDs, no model rewrite; uncertainty review; aliases; per-passage override; only changed segments rerender | Integration tests pending |
| Exports | Real MP3/M4B decode, chapter metadata, portable archive with validated source/timings | Real FFmpeg MP3/M4B decode, duration/chapter metadata and project source/audio checksums passed with test-tone input |
| Migration | Original EPUB preserved; voices/audio private; exact/approximate/unmatched mapping visibly distinguished | Real migration review pending |

## Required real-system gates

- Clean Windows installation and launcher works without a developer environment. Test tray lifecycle, updates, companion identity and engine installation.
- Real Kokoro and Qwen narration on installed Windows hardware: measure omissions/repetitions, pronunciation, voice consistency, generation speed and memory. Confirm no silent substitution.
- Interrupt a complete book render, restart the PC/companion, and verify every required segment appears once in final exports.
- Inspect actual simulator screenshots in dark/light and cream reader modes, small/large devices and enlarged text. Compilation alone is insufficient.
- Download the exact published release IPA, verify checksum and structure locally, and record its release URL and verification report.
- Physical iPhone: LiveContainer import, Files import, Keychain persistence, offline opening, Bluetooth controls, incoming interruption, reconnection, and at least one hour of screen-locked playback.

All real-system gates are **NOT RUN** until an evidence entry records an actual result. CI runs only on standard GitHub-hosted runners. Pull requests cannot access private secrets or the user's computer.

## Evidence — 2026-10-02

Windows project environment: 31 tests passed across companion/tests and tests, with one upstream Starlette TestClient deprecation warning. FFmpeg/FFprobe executed actual normalization and encoding; no speech engine or cloned voice was used. GitHub workflow YAML parsed locally; cloud execution has not yet been observed. Public-source preflight passed.


