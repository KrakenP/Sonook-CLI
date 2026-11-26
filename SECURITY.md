# Security and privacy

## Report a vulnerability privately

On the upstream GitHub repository, open **Security → Report a vulnerability** if private reporting is enabled. If that option is unavailable, open a public issue asking maintainers for a private contact, and send technical details through the private channel they provide. Include the engine version or commit, macOS version, affected command or endpoint, expected behavior and observed impact. Use a minimal original fixture. Keep manuscripts, workspace databases, audio samples, access tokens and pairing codes out of the report. [GitHub private reporting guide](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately)

## What stays on your Mac

Analysis, voice design, synthesis, ASR and rendering use local providers. The default workflow keeps manuscripts, notes, voice references and generated assets in the operator's workspace. A local model failure is reported to the caller. Switching to an external provider requires an explicit choice. SwiftPM retrieves code at build time, and operators obtain and register model weights separately.

The workspace can contain recoverable text, voice cards, reference recordings and playback history. Protect it and its backups with the access controls appropriate to your Mac. Running `sonook publish` creates a local distribution directory. Recipients of a pack can read its transcripts, public character summaries and citation excerpts as well as play its audio. Review those fields and the rights to the content before sharing a pack. [Public character and file contracts](docs/specs/audiopack-v1.md)

## Pairing, access and revocation

- `sonook serve` defaults to `127.0.0.1:8765`. The local health endpoint is public. Protected endpoints require a bearer token, including on loopback. For a non-loopback deployment the server requires explicit LAN opt-in and a configured TLS identity. The CLI's `--allow-lan` flag alone does not supply a certificate.
- Create a challenge locally with `sonook server pair-code --scopes catalog:read,media:download`. The six-digit code expires after 300 seconds by default. The client submits `challenge_id`, `code` and `device_name` to `POST /v1/pair/confirm`. The server atomically consumes a valid challenge once and returns a 256-bit bearer token. The pairing output contains credentials and belongs with the intended client.
- The server stores SHA-256 digests of codes and tokens. The client should keep its token in private storage such as Keychain. Tokens inherit the scopes on the challenge and default to a 90-day lifetime. Grant a player only the scopes it uses. Catalog, media download, playback sync, context queries, job access and device administration have distinct scopes. Sync checks that submitted events belong to the authenticated device.
- List devices with `sonook server devices`. Run `sonook server revoke <device-id>` if a token is lost or the device is retired. Subsequent protected requests using the revoked token receive `401`. Expired or invalid credentials also return `401`. A valid credential lacking the required scope returns `403`. Revocation controls future requests. A downloaded offline copy remains on the device.

## Untrusted inputs and extensions

Treat manuscripts, EPUB entries, knowledge sources and model output as data. Preserve source spans, validate model-produced structure, and keep failed or uncertain readings in review. Spoiler-safe queries restrict retrieved chapters and segments and check generated answers. Speaker likenesses and adaptations require appropriate consent.

Pack readers enforce a path allowlist, regular files, bounded sizes, SHA-256 verification and a closed character schema. Media requests use a registered release and open path components relative to its directory, without following symlinks. A digest verifies file integrity. Authentication and TLS across a network establish the channel through which the client obtained it. [Validation and download rules](docs/specs/audiopack-v1.md)

Optional effects helpers run as separate local executables with the user's permissions. Configure only a trusted program. The bridge supplies a request file and validates output audio and license metadata. Source text does not select a shell command. A process boundary does not sandbox a helper. [Provider and audio licensing](docs/THIRD_PARTY_LICENSES.md)
