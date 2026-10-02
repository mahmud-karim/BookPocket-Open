# Shared contract v1

JSON keys use snake_case. IDs are opaque strings. Times are ISO8601 UTC unless an audio duration/offset in seconds. Never identify source content by display page. Errors use HTTP statuses and `{ "detail": "actionable explanation" }`. All /v1 endpoints require a device bearer token except health and the explicitly described pairing endpoints. Local studio administrative access is separate, loopback-only, with same-origin protection and a launcher-provided session credential.

## Data
- Book: `{id,title,author,language,source_sha256,chapters,created_at}`. Chapters: `{id,title,href,segments}`. Segment: `{id,text,kind,locator}`; kind paragraph/heading; locator is a Readium-compatible JSON object with href, type, optional title, locations, text. Segment IDs are SHA256 of source_sha256 + href + ordinal + original normalized text (UTF-8, newline-separated). Preserve immutable originals and import format version. Clients may create/import the same normalized manifest.
- Voice: `{id,name,engine,kind,language,created_at}`; kind preset/clone/designed. No reference file paths in public API. Engines: `{id,name,available,supports_cloning,languages,license,reason}`. Available means usable installed configuration, never just a known engine name.
- Generation request: `{request_id,book_id,segment_ids,engine,voice_id,language,pronunciation_rules,announce_chapters}`. request_id is a client UUID; repeated identical request returns existing job, conflicting payload gives 409. pronunciation_rules: array of `{term,replacement,enabled}`. Optional later `cast` maps segment ID to voice ID without changing other semantics.
- Job: `{id,book_id,status,engine,voice_id,segment_ids,completed_segments,total_segments,created_at,started_at,finished_at,generation_seconds,error,assets}`. Status queued/running/paused/completed/failed/cancelled. Assets: `{id,segment_id,media_type,duration,sha256,bytes,url,timings}`. timings: `{start,end,start_offset,end_offset}` offsets into original segment text, Unicode scalar offsets; native clients convert explicitly. Job completed only when every required segment has a validated artifact.
- Position: `{book_id,locator,asset_id,audio_seconds,updated_at}`. Library metadata and positions are local first; companion upload explicit.

## Device API routes
- GET /v1/health -> `{api_version:"1",name,version}` (public, no private inventory).
- GET /v1/engines -> `{engines:[]}`; GET /v1/voices -> `{voices:[]}`.
- POST /v1/voices multipart: name,engine,language,reference,optional transcript -> Voice. GET /v1/voices/{id}; DELETE /v1/voices/{id}.
- GET /v1/books -> `{books:[]}`; POST /v1/books multipart file (EPUB/TXT), optional manifest (serialized Book without created_at) -> Book. GET /v1/books/{id}; GET /v1/books/{id}/source -> original file. Book ingestion bounded and archive-safe. DELETE /v1/books/{id} only explicit user action.
- POST /v1/jobs -> Job (202); GET /v1/jobs -> `{jobs:[]}`; GET /v1/jobs/{id} -> Job.
- POST /v1/jobs/{id}/cancel, /retry, /pause, /resume -> Job. Completed immutable artifacts can be reused; in-flight generation may finish but must not publish into cancelled job.
- GET /v1/assets/{id} -> audio bytes with range and checksum support. Assets require authorization; URL is API-relative, never an embedded token.
- POST /v1/jobs/{id}/export `{format:"m4b"|"mp3"|"project"}` -> export asset metadata; may introduce asynchronous export job when needed.

## Pairing
- Local studio POST /v1/admin/pairing-tickets -> `{id,code,expires_at}`. Code random >=8 characters, hashed at rest, expires in 10 minutes.
- Phone POST /v1/pairings `{code,device_name}` -> `{id,poll_token,status:"pending"}`; rate-limited, code consumed for a single pending request.
- Local studio GET /v1/admin/pairings -> pending devices; POST /v1/admin/pairings/{id}/approve or /reject.
- Phone GET /v1/pairings/{id} with Authorization: Bearer poll_token -> pending/rejected/expired or `{status:"approved",device_token,device_id}`. Make successful exchange retryable for bounded expiry to survive dropped response.
- Local studio GET /v1/admin/devices; DELETE /v1/admin/devices/{id} revokes. Phone DELETE /v1/devices/current revokes self. Store only hashes of long-lived tokens; Keychain on iOS.
- Local HTTPS identity is verified from QR certificate SHA256 before token exchange; never global trust bypass. User-configured remote HTTPS must pass normal OS validation. HTTP restricted to loopback development only.

## Compatibility

## Additions: studio setup and casting
- The local studio is served on loopback HTTP 8782; the phone endpoint uses pinned HTTPS 8783. GET /v1/admin/connection returns `{url,certificate_sha256}`. QR payload is `{url,certificate_sha256,code}`. A development listener uses HTTP only on loopback.
- POST /v1/admin/engines/{kokoro|qwen3}/install starts model installation. GET /v1/admin/engines/installations returns `{installations:[{engine,status,error,started_at}]}`. Actual synthesis/model validation precedes availability.
- GET/PUT /v1/admin/analyzer uses `{url,model,api_key?}`. GET never returns the key, only `configured,url,model,has_api_key,hosted`. Changing origin must not forward an existing key. Hosted analysis requires explicit per-request `allow_hosted:true`.
- GET/PUT /v1/books/{id}/cast uses `{characters:[{id,name,aliases,voice_id}],assignments:[{id,segment_id,start_offset,end_offset,character_id,confidence,reviewed}]}`. Offsets are Unicode scalar indices, end exclusive, ordered and nonoverlapping within a segment. Analysis suggestions are unreviewed. User-reviewed assignments survive reanalysis.
- POST /v1/books/{id}/analyze `{allow_hosted:false}` returns an asynchronous persisted analysis `{id,book_id,status,completed_segments,total_segments,created_at,error,finished_at?}`; GET /v1/analyses/{id} polls it.
- Generation supports `narration_plan:[{segment_id,start_offset,end_offset,voice_id}]`. Each original source segment produces one joined asset containing every selected voice span and narrator-filled gaps. The ordered plan and voice revisions participate in the cache key. `cast` remains a whole-segment compatibility field.
- Asset `alignment` reports `word` or `sentence`; do not infer word precision from a sentence interval. Scalar offsets always refer to original display text, even when pronunciation substitutions affect synthesis.
- Book `cover_url` is an optional protected API-relative location. GET /v1/books/{id}/cover returns a validated cover image.
- Voice upload accepts optional `trim_start` and `trim_end` seconds. GET /v1/voices/{id}/reference returns a protected local clone reference. External voice adapters need not expose a reference.

API v1 is owned by root. Additive optional fields are allowed; communicate any route/type change to root and the other client implementers. Companion Pydantic models generate OpenAPI and a checked schema snapshot. Shared fixtures verify JSON parsing, span offsets including emoji, restart idempotency and errors across clients.
