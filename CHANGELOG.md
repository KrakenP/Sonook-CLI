# Changelog

## 1.0.0 — Engine release baseline

The first stable Sonook CLI and Swift SDK bring local audio production, quality review and offline distribution into one workflow. Engine SemVer, workspace schema v5 and .audiopack format v1 have independent version numbers.

| Milestone | What shipped in the engine baseline |
|---|---|
| P0 · Native inference | Ran Chinese text analysis, speech synthesis and ASR on Apple Silicon. Measured alternate model loading, memory, reading accuracy and 48 kHz reference-locked synthesis. [Benchmarks](Benchmarks/p0-baseline.md) |
| P1 · Persistent production | Added SQLite-backed jobs, content-addressed assets, resource scheduling, cancellation and checkpoint recovery through shared services. [ADR-0002](docs/adr/0002-p1-storage-workflow-runtime.md) |
| P2 · Audiobooks | Added TXT, Markdown and EPUB import, source-linked character scripts, ASR review, per-segment retakes and chaptered M4B export. [ADR-0003](docs/adr/0003-p2-audiobook-mvp.md) |
| P3 · Long books | Added chapter memory, bounded repairs, speaker reassignment and selective cache invalidation. Verified restart after SIGKILL and a 1,500-segment workflow. [ADR-0004](docs/adr/0004-p3-long-form-reliability.md) |
| P4 · More audio formats | Added story-aware ambience and foley, explicitly authorized drama adaptation and cited private podcasts on the same production pipeline. [ADR-0005](docs/adr/0005-p4-universal-audio-and-soundscapes.md) |
| P5 · Distribution and sync | Added immutable chapter packs, scoped pairing, HTTP Range downloads, offline rewind-preserving sync, cross-edition cursor migration and spoiler-aware queries. [ADR-0006](docs/adr/0006-p5-server-distribution-and-sync.md) |
| P6 · Open-source release | Defined the 1.0.0 install/uninstall and one-command production contract, adopted Apache-2.0, documented .audiopack v1 and published bilingual setup instructions, security guidance and the dependency/model license audit in the source tree. [ADR-0007](docs/adr/0007-p6-engine-1-0-release.md) |

[English quickstart](README.md) · [中文入门](README.zh-CN.md) · [Open format](docs/specs/audiopack-v1.md)
