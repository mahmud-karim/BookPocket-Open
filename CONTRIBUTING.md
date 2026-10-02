# Contributing

Read AGENTS.md, docs/PRODUCT.md, and docs/CONTRACT.md before changing shared behavior.
Keep changes focused and record which observable behavior you tested. Include
accessibility and dark/light screenshots for interface changes when practical.

Never submit private books, recordings, voice clones, credentials, personal network
addresses, generated runtimes, or model weights. Use the original fixtures under
tests/fixtures for reproductions. Run scripts/public_preflight.py before publishing.

Preserve original source files and exact source identities. Do not label an engine
ready before a successful real probe, represent approximate timings as word
alignment, or replace a failed engine silently. Tests must clearly identify test
engines and must not ship them as production capabilities.

New contributions are licensed under Apache-2.0. Preserve dependency notices and
do not copy code with incompatible licensing. Report test and hardware limitations
honestly; simulator success does not establish physical-device behavior.
