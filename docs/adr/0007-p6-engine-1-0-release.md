# ADR-0007 · Engine 1.0.0 open-source release

**Status** — Accepted release contract, 2026-11-26.

## Context

P0–P5 established a native model pipeline, durable workspaces and an offline release format. Third-party producers and players need an installation contract, stable identifiers and the ability to check licensing and file contents before sharing a release. [P5 acceptance](0006-p5-server-distribution-and-sync.md)

## Decision

- **Versioning.** Adopt Engine `1.0.0` as the first stable CLI/SDK baseline. Use a major version for incompatible changes to documented public interfaces, a minor version for backward-compatible features, and a patch for compatible fixes. Workspace schema v5, HTTP `/v1`, pack `format_version: 1` and a work's integer `release_version` evolve independently. [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
- **Installation.** The source release supplies `./scripts/install.sh` and `./scripts/uninstall.sh`. Default to the user prefix `~/.local` or accept `--prefix <dir>`. Install `bin/sonook` together with its SwiftPM/Metal resources. A normal uninstall removes the installed program and its resources and preserves the workspace, exports and independently registered models. Workspace erasure requires a separate explicit purge. The CLI exposes the version and `sonook build <file> --name <title>`. A blocked quality gate leaves the project and audio available for review. [Installation and walkthrough](../../README.md)
- **Licensing.** Adopt Apache-2.0 for Sonook. Use a short project NOTICE. Keep dependency licenses, Apple SDK terms, user-obtained weights, recording rights and optional subprocess-model licenses identifiable at their respective boundaries. [License](../../LICENSE) · [NOTICE](../../NOTICE) · [Audit](../THIRD_PARTY_LICENSES.md)
- **Format.** Publish the immutable v1 directory contract so independent clients can validate bytes, play a chapter and migrate playback position without the production database. Export public character summaries, verified transcripts and authorized citations. Keep private voice assets in the workspace. [Open .audiopack v1 specification](../specs/audiopack-v1.md)

## Pre-release acceptance

The documentation audit reconciled all 14 macOS SwiftPM pins with their upstream license files, checked the recommended weight publishers and removed identifying material from public design and benchmark records. The release integration gate runs the installer and uninstaller against a disposable prefix, checks the documented CLI and test suites, and scans the combined tracked tree for private text and machine identifiers. The standalone documentation branch still has matches in the speech source, test fixtures and check script owned by the companion module. Release readiness for public distribution depends on a clean combined scan. [Contributing](../../CONTRIBUTING.md) · [Security](../../SECURITY.md)
