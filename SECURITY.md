# Security policy

## Supported versions

Only the latest stable release gets fixes. Pre-releases (betas) are for testing.

## Reporting a vulnerability

Don't open a public issue. Use **[Report a vulnerability](https://github.com/organetto8/wordwave/security/advisories/new)**
on the Security tab, which only the maintainer can read.

- You get a first reply within 7 days.
- Once a fix is ready it ships as a patch release, and the advisory is published, crediting you if you wish.

## What's in scope

Wordwave reads WhatsApp Desktop's local database read-only and transcribes voice notes on the Mac. Its only
internet requests go to GitHub over HTTPS: the release list and, when there is a newer version, its download.
An update is installed only if it carries the release key's Ed25519 signature over the app's identifier, the
version and the archive's SHA-256, is newer than the installed version, and unpacks to Wordwave at that version
with an intact code signature. The private key stays on the maintainer's Mac, outside GitHub and CI. **Report a
Bug** opens GitHub's issue form in the browser; the app itself sends nothing. Reports are especially welcome about:

- any way to make the updater install something the release key didn't sign, install an older version, write
  outside Wordwave's own app bundle, or send anything beyond the release-list and download requests;
- a crafted value in WhatsApp's database (a contact name, a file path) that makes Wordwave crash, read a file
  outside WhatsApp's media folder, or open something other than a WhatsApp chat;
- transcripts, names or phone numbers leaking outside the Mac, into logs, or into the diagnostic info.

Bugs in WhatsApp or in macOS's speech recognition belong to their makers.
