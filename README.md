# Book Pocket Open

A local-first EPUB reader and audiobook studio. Read on iPhone, generate narration on your Windows PC, and keep your original books and audio.

**Development preview available:** [download the latest unsigned iOS IPA (0.1.8)](https://github.com/mahmud-karim/BookPocket-Open/releases/download/v0.1.8-preview.1/BookPocketOpen.ipa) and [the compatible Windows installer (0.1.4)](https://github.com/mahmud-karim/BookPocket-Open/releases/download/windows-v0.1.4-preview.1/BookPocketOpen-Setup-x64.exe). Published downloads were retrieved and checksum-verified; [iOS release notes](https://github.com/mahmud-karim/BookPocket-Open/releases/tag/v0.1.8-preview.1) and [Windows release notes and checksums](https://github.com/mahmud-karim/BookPocket-Open/releases/tag/windows-v0.1.4-preview.1) are available. Listen fits on one screen with a book-wide chapter selector, explicit downloaded takes and excerpts, and a downloads tray. Enlarged text also fits the empty Listen screen, and reader/mini-player buttons have corrected touch areas. Generate the current page or chapter with the PC's external OmniVoice Kyon profile directly from the reader, with actionable connection errors. Audio is verified immediately before playback, failed repairs cannot start corrupt recordings, and project imports preserve existing takes on failure. The companion reclaims verified abandoned render files when recovering from an interrupted worker and derives export chapter markers from actual audio frames. Cast edits survive arriving analysis results and reopening the editor within the same app session. See [the verification ledger](docs/VERIFICATION.md) for tested behavior and [the physical iPhone check](docs/DEVICE-CHECK.md) for the remaining device gates.

## Obsidian in the actual app

Simulator screenshots show the original public test book. These are rendered application screens, not design mockups.

<p>
<img src="docs/screenshots/ios-library.png" alt="Native Obsidian library" width="220">
<img src="docs/screenshots/ios-reader.png" alt="Native cream EPUB reader" width="220">
<img src="docs/screenshots/ios-page-narration.png" alt="Exact page narration preview with Kyon and OmniVoice" width="220">
<img src="docs/screenshots/ios-studio.png" alt="Native Obsidian audiobook studio" width="220">
<img src="docs/screenshots/ios-playing-tabs.png" alt="Narration controls above accessible native tabs" width="220">
<img src="docs/screenshots/ios-listen.png" alt="Fixed Listen player with chapter selection" width="220">
</p>

The narration screenshot uses an unpaired simulator. A paired phone exposes **Generate with Kyon** in this panel.

Listen keeps its player controls on one screen, with a chapter selector and a tray for downloaded recordings. The [compact portrait](docs/screenshots/ios-listen-compact.png) and [landscape](docs/screenshots/ios-listen-landscape.png) screenshots show the same controls on an iPhone SE simulator.

The [downloaded chapter panel](docs/screenshots/ios-chapter-takes.png) and [compact panel](docs/screenshots/ios-chapter-takes-compact.png) show separately generated chapters and an alternate excerpt. These isolated offline playback tests use explicitly labelled non-speech tones, not a synthesized narrator.

![Windows Obsidian library](docs/screenshots/windows-library.png)

## The experience

- Native SwiftUI iOS reader using Readium: EPUB and text import, offline books, reading preferences, navigation, bookmarks, highlights, and Apple text-to-speech.
- Generate the current visible page or table-of-contents chapter from the reader with the PC's external OmniVoice Kyon profile. Preview the exact source text, follow durable progress, and download finished narration for offline playback.
- Listen without scrolling; choose chapters for on-device reading or browse downloaded chapter recordings across the book. Alternate takes and excerpts remain explicit choices. Keep playback speed, sleep timer and transport controls together.
- Windows companion and an Obsidian desktop studio: local library, durable narration jobs, voice collection, device approval, and audio exports.
- Managed Kokoro preset narration and Qwen3-TTS voice cloning, installed separately. Optional integration with an existing VoiceStudio service.
- Full-cast narration from exact source passages, with editable voices and explicit review of model suggestions.
- No reading account. Original files, model runtimes, credentials, and audio stay outside the source checkout.

The interface uses charcoal, graphite, warm white, and restrained champagne accents, with coordinated light mode and independent reader backgrounds.

For profiles already created in a separate VoiceStudio installation, see [the connection and narration guide](docs/VOICE-STUDIO.md).

## Develop on Windows

Requirements: Python 3.11 or later, Node.js 22.12 or later, and FFmpeg/FFprobe on PATH for audio export. Model environments are separate from the application environment; their installers report actual readiness after a synthesis probe.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --require-hashes -r tests/requirements-test.lock -r scripts/build-requirements.lock
.\.venv\Scripts\python.exe -m pip install --no-deps --no-build-isolation -e './companion'
cd studio
npm ci
npm run build
cd ..
.\.venv\Scripts\bookpocket.exe serve --tray
```

The launcher opens the authenticated studio on loopback HTTP port 8782. The phone endpoint uses HTTPS on port 8783 with a locally generated certificate pinned during pairing. Keep the studio launcher link private. Pairings require approval on the PC. Use `--public-url https://YOUR-PC:8783` when automatic LAN address selection does not match the network your phone uses.

For UI development, run `npm run dev` in `studio` and launch the companion in development mode on the proxy port:

```powershell
.\.venv\Scripts\bookpocket.exe serve --dev --port 8782
```

Development mode is loopback-only. Open the studio with the launcher's session credential; do not place it in source files, screenshots, or issue reports.

```powershell
.\.venv\Scripts\python.exe -m pytest companion/tests tests
cd studio
npm test
npm run build
```

## iOS builds

The native app targets iOS 18+. On a Mac with Xcode and XcodeGen, run `xcodegen generate` in `ios`, open `BookPocketOpen.xcodeproj`, and select the `BookPocketOpen` scheme. GitHub Actions runs simulator tests before creating a verified unsigned iPhoneOS ARM64 IPA. Unsigned packages require a compatible sideloading workflow; they are not App Store installations. Physical iPhone playback and sideload checks are recorded separately from CI.

## Architecture and scope

[Product plan](docs/PRODUCT.md) · [API contract](docs/CONTRACT.md) · [Verification](docs/VERIFICATION.md)

Text identities refer to immutable source passages. Font changes and pagination do not change narration identities. Pronunciation substitutions affect synthesis only. Jobs persist in SQLite and cache individual passages so retries can reuse completed audio. Speech timing precision is explicitly reported; sentence timings are not represented as word alignment.

## License

Original project code is Apache-2.0. Dependencies and model weights keep their own licenses; see [NOTICE](NOTICE). Model downloads are optional and are not included in this repository. The synthetic test book is original project fixture text. Voice references and books must be supplied by the user.
