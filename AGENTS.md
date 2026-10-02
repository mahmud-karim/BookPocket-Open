# Book Pocket Open

Build the approved native iOS reader and Windows narration companion. Read docs/PRODUCT.md and docs/CONTRACT.md before changing shared behavior. Do not shrink the goal to demos or UI-only stubs.

## Ownership
- Root owns shared contracts, integration, public release, and the React desktop studio.
- iOS agent owns ios/.
- Companion agent owns companion/.
- Verification agent owns tests/ and .github/ when assigned.
- Work in assigned directories. Coordinate contract changes with the lead. Never revert another agent's work.

## Product invariants
- New code is Apache-2.0. Never copy AGPL application code into this project; external service integration is fine. Preserve third-party licenses.
- Never commit private books, cloned voice references, credentials, personal hosts, old connector configuration, or existing app history.
- Reading requires no account, server, or PC. Original publications are preserved.
- Text/audio identities use immutable source spans, not screen pages. Pronunciation changes never change displayed book text.
- Jobs are durable, cancellable, and resumable; no false ready states, simulated progress, or silent engine changes.
- Obsidian is the design reference: charcoal #111416, graphite #1C2125, champagne #DCC59D, warm white #F4F1EA. Accessible native controls and restrained surfaces. Coordinated light theme; independently configurable reader background.
- Test real outcome boundaries. Synthetic engine fixtures must be explicit test-only capabilities and never advertised as installed TTS models.
- Use existing proven GitHub/macOS build scripts as reference; don't assume a compile proves real iPhone behavior.

