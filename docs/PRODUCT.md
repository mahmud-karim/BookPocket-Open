# Approved product and implementation scope

## Goal
A professional open-source offline iPhone/iPad reader and optional Windows audiobook studio, built with the approved Obsidian theme. Ship reliable narration first, then full cast; both milestones belong to the goal. Existing Book Pocket and Voice Pocket installations remain intact.

## Decisions
- Apache-2.0 original code; fresh public Git history and sideloaded IPA releases first.
- iOS 18+, SwiftUI with Readium EPUB rendering. Immediate Apple speech read-aloud; offline books and audio. Original EPUB storage, Files/share import, TXT import, bookmarks, highlights, search, chapter navigation, font/theme preferences, persistent text/audio location, background audio, lock-screen controls, speed and sleep timer.
- Windows Python/FastAPI companion with SQLite durable queue, managed optional engines, local React studio and tray launcher. English required quality baseline; expose only truthful installed language capabilities.
- Preset Kokoro and Qwen3-TTS 0.6B Base cloning are the public baseline. Existing VoiceStudio API integration is optional; its OmniVoice pretrained weights are noncommercial. Pocket TTS is a subsequent CPU clone adapter. No paid API required for reading or narration.
- Pair authenticated devices, HTTPS identity pinning on LAN, optional Tailscale remote access. Phone reading remains independent of PC availability. No shared hosted account service in v1.
- Source-span generation: selection, chapter, book; preview and alternate takes; pronunciation rules; chapter announcement with pause; incremental rendering, restart recovery, cancel/retry, measured elapsed time and ETA. Single GPU-heavy task initially. M4B/MP3/project export; alignment and synchronized reading.
- Full-cast milestone: exact-source-span speaker analysis, persistent character aliases/cast, local OpenAI-compatible analyzer plus opt-in user-key hosted API, review uncertain lines, passage-level overrides, scene preview, incremental rerender. No model rewriting book text.
- Optional one-time migration of original EPUBs, old audio, pronunciation and available voice references. Approximate mappings must be labelled; keep unmatched recordings as legacy audio. Personal voice samples excluded from public repository.
- PDF/OCR, Android, App Store, cloud multi-user accounts are later scope.

## Design
Obsidian: deep charcoal with champagne accent, book-forward hierarchy, clean sans-serif controls, comfortable serif reading, restrained waveforms and dividers. Dark default and coordinated light theme; reading surface can be dark, cream, or white independently. No mock analytics, decorative AI sparkle buttons, unnecessary captions, or implementation jargon. Library / Listen / Studio navigation; immersive reader hides tabs. Desktop follows same palette with a persistent sidebar and compact player.

The reader combines the book and player. **Read aloud** opens narrator selection without starting playback: **On-device**, **Kyon**, or **Full cast**. On-device speech is immediately available. PC narration controls stay disabled until a verified take for the selected narrator and current source location is ready. **Generate** first asks for **Current page** or **Current chapter**; full cast uses the saved reviewed cast. Generation continues independently of dismissing the player panel, and downloaded matching takes remain playable offline.

The approved reader concept keeps the cream publication visible above a compact charcoal player. Narrator choices remain visible together, followed by a chapter selector, restrained transport and a full-width champagne Generate button. Choosing page or chapter prepares the immutable source snapshot and starts generation when the selected voice is available. Preview and production details are secondary surfaces. Normal controls do not scroll; accessibility text sizes use an adaptive full-height presentation. An existing paired phone can verify and save the same PC's public HTTPS address while away from home, retaining its device credential and downloaded library.

## Delivery gates

Linux/Windows tests, real installed Windows workflow, macOS simulator unit/UI tests and inspected screenshots, unsigned device ARM64 IPA with verified published checksum. Real iPhone installation, Keychain, import, Bluetooth/interruption handling, and one-hour screen-locked playback remain explicit device gates, never silently claimed. Full-book interrupted render must produce complete nonduplicated output. Public CI cannot execute untrusted PR code on the user's PC or access private credentials.

## Milestones
1. Shared contracts, isolated modules, public fixtures, CI.
2. Working offline native reader and device build.
3. Paired PC, real voice generation, downloaded aligned playback.
4. Complete v1 durable book rendering, desktop installation, exports, migration, real tests.
5. Full cast with analysis, review, per-span casting and repair.
