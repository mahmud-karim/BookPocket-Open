# Verification ledger

Evidence current as of 2026-10-02. Deterministic fixtures, real speech synthesis, browser checks, installed Windows packages, iOS Simulator and physical iPhone checks are separate gates. A passing check in one category does not imply the others passed.

## Verified behavior

| Boundary | Evidence and limits |
| --- | --- |
| Public source and fixtures | Public-source preflight passed. Original EPUB/text and non-speech WAV provenance is checked. EPUB ZIP metadata is fixed across Windows/Linux; shared contract fixture hashes regenerate with the source. |
| Core tests | Latest local locked environment: 39 tests passed. Authentication, expiry/reuse/revocation, source preservation, malformed and hostile EPUBs, Unicode scalar identities, idempotency conflicts, restart/retry, cache corruption, cancellation, casting and export boundaries are covered. One upstream TestClient deprecation warning remains. |
| Pairing and API privacy | Local approval required; exchange is retryable; expired/reused codes fail; revocation prevents access. Tests cover protected source/media, loopback admin, browser origins and spoofed forwarding headers. Actual phone TLS-pinning verification remains pending. |
| Original text and casting | Exact scalar ranges, overlap/bounds rejection and emoji offsets pass. Hosted analysis is rejected before any outbound request without explicit consent. Only a changed cast segment rerenders; unchanged segments reuse validated audio. Source text remains unchanged. These tests do not prove LLM speaker-attribution quality. |
| Real Kokoro synthesis | Companion validation generated two segments: 6.925 seconds of speech in 12.141 seconds cold wall time. MP3, M4B and project exports succeeded with checksums. A separate pronunciation/alignment sample mapped “harbor” to spoken “harbour” while retaining eight original-text token ranges within offsets 0–43. |
| Real Qwen cloning | Qwen3-TTS 0.6B Base on RTX 3080 with bfloat16 generated 2.48 seconds of speech in 22.672 seconds cold wall time. The reference was synthetic Kokoro speech, not a private human recording. Earlier float16 CUDA failure was repaired by using the documented bfloat16 configuration. |
| External VoiceStudio | Public API demo profile produced 2.4 seconds of mono 24 kHz audio in 4.484 seconds wall time. OmniVoice's noncommercial weights remain explicitly identified; this is an optional external adapter. |
| Real interrupted-book recovery | An eight-segment, two-chapter original fixture render was terminated after its first durable audio asset. A fresh worker finished 8/8, retained the original first asset ID and produced 32.8 seconds of audio; measured wall time including restart was 35.703 seconds. Independent database inspection confirmed completed status, 8/8 and retained first asset. Final M4B SHA256: `5125b6a359eea679dace072b56a6a5672a8d955e7cee9b977fc835e9e2c54c4e`. This is a complete short fixture book, not a novel-length endurance benchmark or full PC power-cycle test. |
| Export correctness | Independent FFmpeg/FFprobe tests decode actual MP3/M4B output and verify codecs, duration and two contiguous chapter records. Portable projects preserve original EPUB bytes and every audio SHA256. Tone fixtures isolate transport/encoding tests from speech-quality claims. |
| Desktop reader and studio | Browser verification imported The Lantern EPUB, switched chapters and reading preferences, selected exact dialogue, assigned Mira to Bella, saved the cast, generated 4/4 passages with real Kokoro, observed playback progress, changed speed to 1.5x and exported M4B through the UI. No browser page errors were observed. |
| Latest studio and imports | Latest source passes eight studio tests and its TypeScript/production build. An actual browser fresh-take request completed 4/4 with no prior asset IDs reused. A portable project imported through the UI preserved its book and recordings. A separate original-fixture legacy ZIP imported through the UI, appeared on the legacy shelf, played its tone transport sample and reported unmapped audio with zero timing entries. Fractional reference durations no longer violate the trim control's number-input step. These checks do not establish migration quality for private legacy data. |
| Obsidian visuals and accessibility | Root inspected dark/light desktop screenshots at 1440×1000 and mobile web at 390×844. Light-library accessibility scan reported zero violations; six gradient-text contrast checks were inconclusive automatically and received visual review. Known contrast defects were fixed. These web checks do not substitute for native iOS screenshots or VoiceOver/device testing. |

Real-engine timings above are individual smoke measurements, not comparative benchmarks. Omission/repetition accuracy, long-form voice consistency and quality rankings require a larger listening evaluation.

## Windows distribution and reproducibility

- [Lifecycle run 37068591720](https://github.com/mahmud-karim/BookPocket-Open/actions/runs/37068591720) passed fresh installation, windowless tray launch, an in-place upgrade and uninstall. It seeded an actual original EPUB, tone voice reference, TLS identity and settings, reopened the library after upgrade, and verified seven personal-data files survived uninstall. The baseline used the same source packaged as version 0.0.0; this is installer lifecycle evidence, not migration from the old application. Its artifacts still require rebuilding after later source changes.
- Latest studio source passes eleven tests and its production build. A real M4B export streamed through the browser into a browser-private test file sink: 203,811 bytes, SHA256 `038bb96e7263be97ce964516156c4af42881c304961bedba16876d361444be42`, matching companion metadata. This test substituted the file chooser and does not prove native save-dialog behavior. Tests separately cover save cancellation and aborting a failed partial download. Browsers without the file-system save API retain the ordinary buffered-download fallback. The stream follows the browser vendor's [file-system API guidance](https://developer.chrome.com/docs/capabilities/web-apis/file-system-access).

- The application includes its own checksum-pinned official CPython 3.12.10 runtime and built studio. It needs no preinstalled Python, Node.js, Git or developer tools.
- [Hosted run 37041629940](https://github.com/mahmud-karim/BookPocket-Open/actions/runs/37041629940) compiled the unsigned per-user Inno installer, installed it into an isolated runner directory and passed installed-runtime checks. The downloaded installer and portable ZIP matched the CI SHA256 files.
- [Hosted run 37042076790](https://github.com/mahmud-karim/BookPocket-Open/actions/runs/37042076790) additionally passed the real windowless tray-launch gate. Smoke removes developer tools from PATH, verifies API health, built-studio serving, library authentication, relocated-runtime engine virtual-environment creation and FFmpeg execution. Local Windows tray-launch smoke also passed.
- FFmpeg downloads directly from its upstream publisher during setup with a pinned SHA256. Our installer excludes downloaded FFmpeg binaries. Upstream LGPL license and provenance remain with the installed tools; Python and package notices remain in the bundle. Initial setup requires internet. Installers are not code-signed.
- `companion/uv.lock` resolves universal Python >=3.11 dependencies, preserving Windows-only markers. Production/test exports include hashes. CI checks exports for drift, installs with `--require-hashes`, then installs app code with `--no-deps --no-build-isolation`. Build tooling is separately hash-locked. Optional speech models use isolated environments and separate licenses.
- Lock-based installer [run 37042794635](https://github.com/mahmud-karim/BookPocket-Open/actions/runs/37042794635) passed installation and actual tray launch. Cross-platform [run 37042795777](https://github.com/mahmud-karim/BookPocket-Open/actions/runs/37042795777) passed Windows, Ubuntu and studio checks. Every release must rebuild after final application changes.

CI uses standard GitHub-hosted runners. Untrusted pull requests have no access to private credentials or the user's computer. Local validation data, generated speech and screenshots remain excluded from public source.

## iOS and release gates still open

- Run native unit/UI tests, including shared contract parsing and scalar-to-UTF16 mapping; inspect actual simulator screenshots across dark/light/cream reader modes, small/large devices and enlarged text.
- Verify original EPUB formatting, Files/share import, bookmarks/highlights/search, persistent position across font changes/rotation/relaunch and PC-independent offline reading.
- Verify phone certificate pinning, Keychain persistence, interrupted-download recovery, checksum checks, original-text alignment and offline listening.
- Build a real unsigned iPhoneOS ARM64 IPA. The verifier's rejection tests pass, but a simulator build is not a device package. Download the published IPA, compare its SHA256 and inspect archive/executable metadata before release handoff.
- Physical iPhone: LiveContainer installation, Files import, Keychain persistence, Bluetooth/lock-screen controls, interruptions/reconnection and at least one hour of screen-locked playback remain unverified.

## Remaining product-level validation

- Novel-length rendering, actual PC sleep/power-cycle recovery, disk exhaustion, model memory pressure, cancellation during real synthesis and consistent voice quality across chapters.
- Real LLM attribution across ambiguous/nested dialogue and aliases, user-review preservation during analysis, and full multi-voice listening evaluation. Current source-span/privacy/cache tests and manual cast UI checks cover only their stated boundaries.
- Optional migration from old applications: original source preservation, private voice/reference handling and explicit exact/approximate/unmatched recording mapping require final real-data validation.
- Installer upgrades/uninstall data preservation and production connection behavior on a second clean Windows machine require final checks. Hosted fresh installation and actual tray startup are already verified.

