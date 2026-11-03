# Contributing to Wordwave

Thanks for helping. Wordwave is a personal project maintained in spare time, so this page explains what to
expect and how to make a report or a change land quickly.

## What Wordwave is, and isn't

- Everything runs on the Mac. No uploads, no account, no telemetry: voice notes and transcripts never leave it.
  Changes that add a network request are declined. The one exception is the signed update check with GitHub.
- WhatsApp's data is only ever read, never written.
- Apple frameworks first, and no package dependencies.
- English and Italian are both complete. New text the user sees needs both.

## Asking, reporting, requesting

| You want to… | Go to |
|---|---|
| Ask how to do something, or discuss an idea | [Discussions](https://github.com/organetto8/wordwave/discussions) |
| Report a bug | **⋯ ▸ Report a Bug…** in the menu bar panel, or the [bug report form](https://github.com/organetto8/wordwave/issues/new?template=bug_report.yml) with **Copy Diagnostic Info** |
| Ask for a feature | **⋯ ▸ Request a Feature…**, or the [feature request form](https://github.com/organetto8/wordwave/issues/new?template=feature_request.yml) |
| Report a security problem | [Private report](https://github.com/organetto8/wordwave/security/advisories/new), never a public issue ([policy](SECURITY.md)) |

Issues and pull requests are in English. Never paste a transcript, a contact name or a phone number: issues are public.

## How issues are handled

- **First reply within 7 days.** Usually sooner; holidays happen.
- **Labels** say where an issue stands:

  | Label | Meaning |
  |---|---|
  | `bug` / `enhancement` | Set by the form you used |
  | `needs-info` | Waiting for an answer from the reporter |
  | `confirmed` | Reproduced, or accepted as a request |
  | `help wanted` / `good first issue` | Open for a pull request |
  | `duplicate` / `wontfix` | Closed with a link or a reason |

- **`needs-info`** comes off by itself when the reporter replies. With no reply for 14 days the issue is
  marked stale, and 7 days later it closes. A comment reopens the conversation at any time.
- **Confirmed bugs** go into the next patch release; crashes and data loss first.
- **Requests** are weighed by how many people need them (👍 on the issue) and whether they fit the principles
  above. A `wontfix` always comes with the reason.

## Pull requests

1. For anything bigger than a small fix, open an issue first, so we agree on the approach before you write it.
2. Branch from `main`. One topic per pull request.
3. Follow the build steps in the [README](README.md#build-and-run). `xcodebuild test -scheme Wordwave` must pass;
   CI runs it on every pull request.
4. New strings: add the Italian translation in `Wordwave/Localizable.xcstrings`.
5. Update the README if behaviour changes, and add a line under **Unreleased** in `CHANGELOG.md`.
6. Write commit messages in English, in the imperative ("Show the transcript language on cards").

Wordwave is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md), with all other rights
reserved by the author. By contributing you agree that your contribution is licensed to the author under the
same terms, and that the author may also license it commercially. You also agree to follow the
[code of conduct](CODE_OF_CONDUCT.md).

## Releases

How versions are numbered and published is in [docs/RELEASING.md](docs/RELEASING.md).
