# Changelog

Every notable change to Wordwave. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/). How releases are made: [docs/RELEASING.md](docs/RELEASING.md).

## [Unreleased]

## [0.2.0-beta.1] - 2026-11-04

### Changed

- Voice notes from chats and groups you muted or archived in WhatsApp are skipped: no transcript, no notification,
  no card. The mute and archive state is checked when Wordwave picks up the voice note, so a note received while a
  chat was muted stays skipped after you unmute it.
- **⋯ ▸ Copy Diagnostic Info** shows where Wordwave found WhatsApp's mute and archive state, and how many voice notes
  it skipped since launch.

## [0.1.0] - 2026-11-03

### Added

- **Automatic updates.** Wordwave checks its GitHub releases every 6 hours, and on **⋯ ▸ Check for Updates…**.
  A new stable version installs by itself when Wordwave is idle (no transcription running, no panel open), then
  Wordwave reopens and a notification links to what's new; after **Check for Updates…** it asks before relaunching.
  A beta is never installed on its own: a notification announces it, at most once a day, and clicking it offers
  **Install Beta**, **Not Now** (the default) and **Skip This Beta**.
- A release that fails verification is skipped for good and never offered as a download, so a release published
  without the key can't hide an older genuine one. A failed check waits an hour before trying again.
- Every update is checked before it is installed: the archive must carry the release key's Ed25519 signature
  over the app, the version and the archive's SHA-256, and unpack to Wordwave at that version with a valid code
  signature.
- **⋯ ▸ Report a Bug…** and **⋯ ▸ Request a Feature…** open a short form with the same fields as the GitHub
  issue forms, then open the issue on GitHub already filled in, with the diagnostic info, for you to submit.
- **⋯ ▸ Copy Diagnostic Info**: versions, settings, counts and recent errors, with no names, numbers or transcripts.

### Changed

- Releases now also carry `Wordwave-x.y.z.zip`, its `.sig` signature and `SHA256SUMS.txt`, next to the DMG.

## [0.0.1] - 2026-11-03

### Added

- Menu bar app that transcribes the WhatsApp voice notes you receive, on-device, by reading WhatsApp Desktop's
  local database read-only.
- Unread counter in the menu bar and a notification with the transcript for each new voice note.
- Cards with sender, profile picture, transcript and arrival time; a click opens the chat and marks it as seen.
- Seen voice notes in a collapsible section, kept for 7 days.
- Transcription language that follows the system, or picked from the ⋯ menu.
- English UI with Italian translation, and launch at login.

[Unreleased]: https://github.com/organetto8/wordwave/compare/v0.2.0-beta.1...HEAD
[0.2.0-beta.1]: https://github.com/organetto8/wordwave/compare/v0.1.0...v0.2.0-beta.1
[0.1.0]: https://github.com/organetto8/wordwave/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/organetto8/wordwave/releases/tag/v0.0.1
