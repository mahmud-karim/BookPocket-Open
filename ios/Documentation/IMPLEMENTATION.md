# Native app implementation

The application is native SwiftUI with a Readium EPUB navigator wrapped at its UIKit boundary. Xcode uses Swift 5 language mode for Readium 3 compatibility and modern async/await, Observation, and iOS 18 APIs. No private service endpoint is embedded.

## Dependencies and reviewed guidance

- Readium Swift Toolkit 3.11.0, exact version; source reviewed at `d82f44f4f05d87add9e22a8b75abbd61dce745dd`. BSD-3-Clause.
- Readium ZIPFoundation 3.0.1, exact version; async archive API. MIT.
- SwiftUI Pro guidance reviewed at `be297ff80dddec529af1f9b1f1f114aab6c9d11c` from https://github.com/twostraws/SwiftUI-Agent-Skill. MIT. Guidance reviewed locally, not installed globally. iOS 18 deployment and approved Readium integration override its default target/framework preferences.

## Data and trust

SQLite WAL stores local library and companion metadata. Original publications stay in app Documents/Library; TXT receives a separate generated EPUB. Locators are serialized Readium locators, independent of visual pagination. Import enforces file and archive bounds and rejects traversal, symlinks, and duplicate archive paths.

Companion credentials are in Keychain with device-only after-first-unlock protection. QR pairing pins the SHA-256 fingerprint of the exact leaf certificate for a single HTTPS origin. Without a pin, normal system trust applies. Cross-origin redirects are rejected. Tokens are never embedded in URLs. Pairing requires PC approval.

The scoped `NSAllowsLocalNetworking` declaration permits this local self-signed certificate flow while ATS remains enabled for public domains. The API client independently requires HTTPS and TLS 1.2 or newer; there is no global arbitrary-load exception. This follows Apple's [manual trust](https://developer.apple.com/documentation/Foundation/performing-manual-server-trust-authentication) and [local networking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) guidance.

Submission request IDs are persisted before sending; an uncertain request can be retried without creating a duplicate job. Completed downloads are checked against bytes and SHA-256 and saved atomically. Repeating download continues from completed assets after app termination; an incomplete individual asset is downloaded again. Playback remains offline.

Readium Apple speech synthesis produces text locators; downloaded narration maps Unicode scalar timing offsets into source text, falling back to passage-level highlighting when timing is unavailable. Voice samples can be trimmed/previewed on-device and are uploaded only to the paired companion.

Full-cast analysis is configured on the PC. Phone analysis requires explicit hosted opt-in. Speaker assignments use source ranges and never replacement text. Manual assignments use native text selection; unreviewed suggestions block rendering unless the user chooses narrator fallback.

## Verification

Run `xcodegen generate` in this directory, then `xcodebuild test -project BookPocketOpen.xcodeproj -scheme BookPocketOpen -destination 'platform=iOS Simulator,id=DEVICE_ID' CODE_SIGNING_ALLOWED=NO`.

Unit tests cover TXT source preservation and deduplication, SQLite restart persistence, contract decoding, Unicode scalars, and HTTPS/resource validation. UI tests import an original synthetic EPUB, open the native reader, inspect contents, and retain screenshots. These are useful boundaries; they do not prove full on-device behavior.

Required physical iPhone gates remain LiveContainer import, Keychain persistence, Files handoff, camera pairing, Bluetooth/interruption handling, and an hour of screen-locked playback. Real companion and voice-engine generation also require connected integration evidence. Do not claim these from simulator or compile results.

## Build artifacts

`project.yml` generates BookPocketOpen.xcodeproj. The app identifier is `org.bookpocket.open`. The PNG icon is original geometric artwork and reproducible with `python Scripts/generate_icon.py` and Pillow. Never package `.reference` or user documents.
