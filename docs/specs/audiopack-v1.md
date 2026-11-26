# Open .audiopack v1 specification

An `.audiopack` is an immutable directory containing one playable edition of a book, drama or podcast. A player can read it offline using a JSON decoder, SHA-256 and a chapter audio decoder. No Swift runtime, model weights or workspace database is needed.

## Layout and encoding

```text
Example_v1.audiopack/
├── manifest.json
├── metadata.json
├── chapters/001.m4a
├── transcripts/001.json
├── characters.json
├── timeline.json
├── checksums.json
├── references.json       (optional)
└── artwork.jpg           (optional)
```

JSON files use UTF-8 and the exact, case-sensitive keys below. IDs and timestamps are strings. Timestamps use ISO 8601 with a timezone. Counts, frames, bytes and milliseconds are integers. Durations in seconds are JSON numbers. Fields are required unless marked optional. An optional scalar can be absent or null. Where a list has no items, encode an empty array. Hash the file bytes as delivered, including whitespace.

### manifest.json

| Field | Type and meaning |
|---|---|
| `format_version` | Integer, exactly `1`. Reject unknown versions before loading media. |
| `project_id`, `release_id` | Nonempty opaque IDs. The project identifies the work across editions. The release identifies one immutable edition. |
| `release_version` | Positive integer edition number within the project. Independent of engine SemVer. |
| `production_mode` | `audiobook_verbatim`, `audio_drama_adapted` or `private_podcast`. |
| `audio_mode` | `dry`, `ambient` or `soundscape`. The delivered chapter audio contains the final mix. |
| `created_at` | Creation timestamp. |
| `total_duration_seconds`, `total_byte_size` | Timeline duration and sum of the sizes of **all files**, including the final manifest and checksums. |
| `required_files`, `optional_files` | Arrays of pack-relative paths. The reference writer lists the five required root JSON files and every chapter audio/transcript pair as required. Optional entries may be absent. |
| `required_capabilities` | Array of capability strings. The writer emits `audio.m4a` or `audio.wav`, plus `sync.v1`. A client must check the capabilities it needs before offering playback or sync. |
| `chapters` | Nonempty array in playback order, with unique chapter IDs and strictly increasing positive chapter numbers. Numbers can have gaps for selected chapters. |

Each chapter object has `chapter_id`, `chapter_number`, `title`, `audio_relative_path`, `transcript_relative_path`, `duration_seconds`, `sample_rate` (Hz), `byte_size` (encoded audio only) and `file_sha256` (encoded audio digest). Follow the two explicit paths. The reference writer pads the chapter number to at least three digits. Each path belongs to exactly one chapter. V1 supports AAC in an M4A container and PCM WAV, one file per chapter.

This one-chapter conformance example uses a two-second mono WAV at 48 kHz (16-bit zero samples, standard 44-byte PCM header). Its metadata is `{"schema_version":1,"title":"Example","language":"en","created_at":"2026-01-01T12:00:00Z"}`. The character, transcript and timeline examples below complete the payload. The stated byte total uses compact JSON, sorted keys, UTF-8 and no trailing newlines in any sidecar. Other serializations must recompute the sizes and hashes.

```json
{
  "format_version":1, "project_id":"book-a", "release_id":"edition-1", "release_version":1,
  "production_mode":"audiobook_verbatim", "audio_mode":"dry", "created_at":"2026-01-01T12:00:00Z",
  "total_duration_seconds":2, "total_byte_size":194343,
  "required_files":["chapters/001.wav","characters.json","checksums.json","manifest.json","metadata.json","timeline.json","transcripts/001.json"],
  "optional_files":[], "required_capabilities":["audio.wav","sync.v1"],
  "chapters":[{
    "chapter_id":"ch-1","chapter_number":1,"title":"Arrival","audio_relative_path":"chapters/001.wav",
    "transcript_relative_path":"transcripts/001.json","duration_seconds":2,"sample_rate":48000,"byte_size":192044,
    "file_sha256":"e294409b36a8ac1893b23336eeab5202d3e84ce4f66c7572aa1589c43d43c1ff"
  }]
}
```

### metadata.json and characters.json

Metadata is an object with `schema_version: 1`, `title`, `language` and `created_at`. Optional strings are `author`, `narrator` and `summary`. The writer defaults the language to `zh-CN`.

`characters.json` is an array. Each element has a **closed** set of public keys. An empty catalog is valid.

```json
[{"character_id":"voice-a","canonical_name":"Guide","aliases":[],"persona_summary":"Speaks slowly.","first_appeared_chapter":1}]
```

The first four fields above are required. `aliases` is an array of strings. The optional integer `first_appeared_chapter` is the first included chapter in which this character speaks. A producer projects these fields from its private catalog before serialization. Reject any additional key, even if an ordinary decoder would ignore it. Reject local paths, file URLs, audition-file references, and WAV filenames in public character strings. The Sonook writer also rejects known private anchor IDs, asset hashes and credential values copied into these strings. Keep voice samples, timbre anchors, design prompts, provider bindings and credentials in the production workspace. Transcripts and citation excerpts are readable by recipients and require publication rights.

### transcripts/ and timeline.json

Each chapter transcript is an object. For example, a 2-second chapter with one segment can contain the following transcript.

```json
{
  "schema_version": 1, "chapter_id": "ch-1", "chapter_number": 1, "title": "Arrival",
  "segments": [{
    "segment_id": "s-1", "speaker_id": "voice-a", "speaker_name": "Guide",
    "spoken_text": "Hello.", "source_span": {"unit":"utf8_byte","start":0,"end_exclusive":6},
    "start_ms": 0, "end_ms": 2000
  }]
}
```

The chapter ID, number and title match the manifest. Segments are in playback order, nonempty per chapter, with unique IDs within that chapter. Keep IDs stable across editions. The publisher includes verified script segments. A source span is an absolute half-open byte range in the immutable normalized UTF-8 source document. Both endpoints lie on scalar boundaries, with `0 ≤ start ≤ end_exclusive`. `spoken_text` is the performed text and can differ from the cited bytes in an authorized adaptation.

`timeline.json` uses **book-relative sample frames**. For the transcript above, the corresponding timeline could read as follows.

```json
{
  "schema_version":1, "sample_rate":48000, "total_frames":96000, "total_duration_seconds":2,
  "ambient_mixed":false, "render_fingerprint":"example-render",
  "chapters":[{"chapter_id":"ch-1","title":"Arrival","start_frame":0,"end_frame_exclusive":96000,"sample_rate":48000}],
  "entries":[{"chapter_id":"ch-1","segment_id":"s-1","speaker_id":"voice-a",
    "source_span":{"unit":"utf8_byte","start":0,"end_exclusive":6},
    "start_frame":0,"end_frame_exclusive":96000,"start_seconds":0,"end_seconds":2,"pause_after_ms":0}]
}
```

The fingerprint is an opaque string identifying the render. Chapter markers are contiguous positive-length intervals covering `[0, total_frames)`, in manifest order and at the same positive sample rate. Chapter duration equals its frame count divided by that rate. Total duration equals `total_frames / sample_rate` in both timeline and manifest.

There is one timeline entry for each transcript segment in order, with the same chapter, segment, speaker and source span. Entries stay inside their chapter, have positive length and do not overlap. Gaps may contain pauses. `pause_after_ms` reports the rendered pause after the segment. Each timeline seconds field equals its absolute frame divided by the sample rate. To calculate a transcript endpoint, subtract the chapter start frame, multiply by 1000, divide by the sample rate and round to the nearest integer (ties away from zero). Use chapter-relative milliseconds for player positions.

### references.json, artwork.jpg and checksums.json

`references.json` is an optional array of citation objects. Each has string fields `citation_id`, `source_id`, `source_title`, `chunk_id`, `quoted_excerpt` and `ingested_at`, plus a `source_span` as above and the boolean `is_inference`. The span addresses the cited source. The timestamp records ingestion. The flag distinguishes inference from a sourced statement. The writer emits the file only when references exist. A producer can include a JPEG cover as `artwork.jpg` and declare it optional.

`checksums.json` is an object with `schema_version: 1`, `algorithm: "sha256"` and `files`, a map from every file path **except checksums.json itself** to its 64-character lowercase hex SHA-256 digest. Include `manifest.json` and every physically present optional file. A chapter's digest must also equal its manifest entry. For an authenticated catalog the release record supplies `manifest_sha256` separately. Hashes provide integrity. Publisher identity depends on the trusted channel used to obtain the release.

## Writing and validating a directory

1. Render the chapters and sidecars in a fresh sibling directory. Build the inventory and hash their final bytes. Use a fixed-width 64-character placeholder for the manifest digest to measure the checksums file.
2. Encode the manifest with a candidate total size. Recompute the sum of all file lengths, including that manifest and the checksums file. Repeat until the encoded `total_byte_size` equals the sum. Hash the final manifest, replace the placeholder and write checksums using the same serialization.
3. Validate relative paths **before** opening files. Permit only the named root files and one-level `chapters/*.m4a`, `chapters/*.wav`, `transcripts/*.json` entries. Reject empty or dot-prefixed components, absolute paths, backslashes, colons, NUL, hidden entries and paths containing `voice_audition` (case-insensitive). Pin the directory while reading. Reject symlinks including intermediate directories, hard-linked files, nonregular files and duplicate paths.
4. Bound enumeration, allocation and hashing. Sonook defaults are 100,000 files, 512 MiB per file, 16 GiB total and 32 MiB aggregate JSON. Read the manifest version early. Check inventory and sizes against the actual files before decoding all sidecars, hash audio in chunks, and reject files that change length during validation.
5. Check required files, declared optional files, exact checksum coverage and total bytes. Every nested file belongs to one of the declared chapter pairs. Verify every digest, all version fields, the character allowlist and every chapter/segment/time relationship above. Fail closed on any mismatch. Publish a validated directory atomically under a fresh name and retain older versions for existing cursors.

Test a producer's output using `sonook pack verify ./Example_v1.audiopack --json`. The reference writer and reader are in [DistributionKit](../../Sources/DistributionKit). The serialized contracts are in [AudioCore](../../Sources/AudioCore/ServiceAndSyncContracts.swift) and [AudioRenderKit](../../Sources/AudioRenderKit/AudioRenderKit.swift).

## Downloading a release over HTTP

Pair with the local server and send `Authorization: Bearer <token>`. With `catalog:read`, get `/v1/releases?project_id=<id>`, select the release and request `GET /v1/releases/{release_id}/manifest`. Verify the manifest digest against the catalog. With `media:download`, use `GET /v1/releases/{release_id}/files/{relative_path}` for checksums, chapters and sidecars. Encode path components individually. Resolve them inside the registered release directory.

- A full GET returns `200`, `Accept-Ranges: bytes` and a quoted SHA-256 `ETag`. One byte range is supported per request, in inclusive `bytes=start-end`, open-ended `bytes=start-` or suffix `bytes=-count` form.
- To resume at byte 4096, send `Range: bytes=4096-` and `If-Range` with the saved ETag including the quotes. On `206`, verify `Content-Range: bytes start-end/size` before appending. An ETag mismatch returns the full file with `200`. Replace the partial copy. An unsatisfiable applicable range returns `416` with `Content-Range: bytes */size`.
- Check final byte size and SHA-256 before making media available for offline playback. Fully validate the assembled directory before importing it. A partial download can be kept outside the published directory until complete.

## Offline playback and cursor migration

Queue events locally and POST a JSON array to `/v1/sync/events` with `playback:sync`. Send the device ID returned by pairing. The server checks the ID of every event against the token. Retries must reuse each original device/event ID pair and payload.

```json
[{"schema_version":1,"event_id":"evt-17","device_id":"reader-a","project_id":"book-a",
  "release_id":"edition-1","chapter_id":"ch-1","segment_id":"s-1","position_ms":600,
  "event_type":"rewind","device_sequence":17,"occurred_at":"2026-01-01T12:00:01.05Z"}]
```

`segment_id` is optional. `position_ms` is chapter-relative and nonnegative. `device_sequence` is a nonnegative 64-bit integer assigned by the device. Use a monotonically increasing sequence locally. Allowed event types are `play`, `pause`, `progress`, `seek`, `rewind` and `complete`.

1. Validate nonempty IDs and parseable timestamps. Deduplicate on **(device_id, event_id)**. The original durable event wins. Merge independently per project using ascending **(occurred_at instant, device_sequence, event_id, device_id)**. Compare actual instants across timezone offsets and preserve fractional precision, then compare sequence numerically and IDs lexicographically. This is a deterministic total order using device time.
2. Store newly seen late events in history. Only events strictly later than the current cursor in this order replace it. Position can decrease. A winning `rewind`, or a winning `seek` to an earlier position in the same chapter and release, increments `rewind_preserved_count`. A retry of the same event increments only `duplicate_count`. For example, rewinding from 1500 ms to 600 ms survives late delivery of the older 1500 ms progress event.
3. The response contains `schema_version: 1`, `accepted_count`, `duplicate_count`, `rewind_preserved_count` and optional `cursor`. A multi-project batch returns the cursor for the causally last input's project. Read the current position with `GET /v1/sync/cursor?project_id=<id>` (404 before a cursor exists). Its fields are `schema_version`, `project_id`, `release_id`, `chapter_id`, optional `segment_id`, `position_ms`, `last_event_id`, `last_device_id`, `last_device_sequence`, `last_event_type` and `updated_at`. A client with catalog access can also subscribe to `/v1/events` for `playback_synced` notifications.

On an edition change, validate both packs. Require the same project, a cursor belonging to the old release and chapter, and a destination version at least as new. If the cursor names a segment, it must exist in the old chapter. Otherwise locate the segment containing the old position using half-open millisecond intervals.

Prefer the same segment ID in the same chapter. If it moved, consider matches in other chapters, excluding same-named segments already present in those chapters in the old edition. Reject ambiguous moves. For a match, add the old offset within the segment to the new segment's start, clamping the offset to the new length. For example, a listener 800 ms into a segment now only 500 ms long resumes at its new end. If no mapping exists, retain the chapter and clamp position to its new duration, then resolve the containing segment if present. A missing fallback chapter is an error. Keep last-event identity, sequence, type and timestamp while replacing the release, chapter, segment and position. [Reference merge and migration implementation](../../Sources/DistributionKit/PlaybackSyncEngine.swift)
