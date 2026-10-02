# Book Pocket Open companion

The Windows companion preserves original EPUB/TXT publications, runs a durable SQLite narration queue, and serves the local Obsidian studio and paired devices. Personal data belongs outside the source checkout.

## Development

Use Python 3.11 or newer and FFmpeg on `PATH`. From the repository root:

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install -e "./companion[test]"
.venv\Scripts\python -m pytest companion/tests tests
.venv\Scripts\bookpocket serve --studio-dir studio/dist
```

The normal launcher opens the studio on loopback HTTP port 8782 and serves paired phones over HTTPS port 8783. The launch URL contains an ephemeral session token in its fragment; the studio removes that fragment and retains the token only in session storage. Admin access requires the token, a loopback peer, and an allowed browser origin. HTTPS identity fingerprints are paired through the QR payload. Proxy headers are not trusted. `--dev` is loopback-only HTTP; `--studio-port`, `--port`, and `--public-url` support explicit setup.

On first launch, the phone connection URL uses an available LAN address. Keep the phone and PC on the same network, open Devices in the desktop studio, scan the QR, and approve the named phone on the PC. For a PC with several network adapters, set `--public-url https://<reachable-PC-address>:8783` explicitly. The local desktop studio remains loopback-only. Optional remote access needs a user-configured HTTPS or Tailscale route; this app does not publish a public tunnel.

Configuration and all books, cloned references, SQLite data, models, and TLS keys default to `%LOCALAPPDATA%/BookPocketOpen`. Override with `--data-dir`. Optional `config.json` fields are `public_url`, `voicestudio_url`, and `ffmpeg`. API keys belong in the private data folder; never copy it into a source release.

## Engines and jobs

Install Kokoro or Qwen3 from the studio or `bookpocket install-engine kokoro` / `bookpocket install-engine qwen3`. Each has a separate virtual environment and model cache. Installation validates the loaded model; Kokoro also synthesizes a probe. Qwen Base requires a user voice reference for synthesis. On compatible NVIDIA drivers installation selects official CUDA PyTorch wheels. Qwen uses bfloat16 on supported GPUs and float32 otherwise. No global Python environment is modified.

Kokoro supplies real model token timing. Pronunciation replacement maps that timing back to original Unicode scalar spans. Engines without reliable word timing synthesize bounded sentence portions and expose accurate sentence boundaries. The API never fabricates word timestamps. Full-cast intervals may use different voices inside one paragraph; their audio joins into one segment artifact, with original offsets intact.

Queue changes are transactional. Recovery returns interrupted running jobs to the queue. Completed segments are reused only after checksum validation. Cancellation prevents publishing newly completed audio to the cancelled job. Model package versions and downloaded snapshot commits are recorded in the readiness marker and incorporated into cache identities.

Optional VoiceStudio integration uses its public `/v1/audio/voices` and `/v1/audio/speech` endpoints with the explicit `omnivoice` engine. It exposes real profiles, not OpenAI aliases. VoiceStudio is separately installed; its implementation is not bundled. OmniVoice weights are noncommercial.

| Component | License / distribution |
| --- | --- |
| Original companion code | Apache-2.0 |
| Kokoro 82M weights | Apache-2.0; downloaded into the user's model cache |
| Qwen3-TTS 0.6B Base weights | Apache-2.0; downloaded into the user's model cache |
| VoiceStudio / OmniVoice | Separate optional service; OmniVoice pretrained weights have noncommercial terms |
| Casting analysis model | User-selected local model or explicit hosted provider; its own license applies |

An explicit `take_id` on a generation request bypasses previous takes' cached audio. Retry retains the same take ID and reuses its completed segments. A new take can vary with sampling engines; deterministic engines may produce the same waveform.

## Portable projects and migration

Completed jobs export M4B, MP3, or a portable ZIP. `POST /v1/projects/import` accepts a multipart `file`. A native project ZIP contains `project.json`, `source.epub` or `source.txt`, and `audio/<asset-id>.wav`. Cast characters, aliases, exact assignments, and voice metadata are included. Private voice reference files and transcripts are excluded unless the export request explicitly sets `include_voice_references: true`. Import validates original and audio hashes, source ranges, and archive limits. Missing references are returned as `unresolved_voices`, never advertised as usable clones. An existing library cast is preserved; the imported cast also remains attached to the imported production metadata. Re-importing the same archive is idempotent.

The same route accepts an explicitly prepared legacy ZIP with this `legacy.json` format:

```json
{
  "format_version": 1,
  "kind": "bookpocket_legacy",
  "books": [{"legacy_id": "old-book", "source": "books/original.epub", "title": "Book", "position": "old-page-key"}],
  "recordings": [{"book_legacy_id": "old-book", "path": "audio/take.wav", "title": "Saved take", "source_text": "Optional exact original text"}],
  "voices": [{"name": "My voice", "path": "voices/reference.wav", "engine": "qwen3", "language": "en", "transcript": "Optional reference transcript"}],
  "pronunciation_rules": [{"term": "Example", "replacement": "Ex ample", "enabled": true}]
}
```

Every referenced file must be inside the archive. Original books and original recording bytes remain preserved. Legacy audio is normalized for playback and listed separately by `GET /v1/legacy-recordings`; a unique text match is labelled `text_match_without_timings`, otherwise `unmapped`. Old display-page positions are preserved as unmapped metadata. No legacy timing is represented as verified alignment. Imported pronunciation rules are available from `GET /v1/pronunciations`; existing rules win conflicts. Voice references are private and require recordings the user is authorized to use.

The legacy app needs an authenticated export or local original files to prepare this archive. This companion never guesses private credentials or rewrites the old application.

## Casting analysis

Configure a local OpenAI-compatible endpoint and model through `PUT /v1/admin/analyzer`, for example `http://127.0.0.1:1234/v1` for an already running local server. An HTTPS hosted endpoint requires explicit `allow_hosted` consent on each book-analysis request. API keys are write-only and are cleared when the endpoint origin changes. Analysis runs asynchronously, persists status, validates exact scalar ranges, and preserves reviewed edits. The analyzer returns verbatim source anchors; the companion computes offsets and rejects missing or ambiguous anchors. The model cannot replace publication text. All generated speaker suggestions require user review before production narration.
