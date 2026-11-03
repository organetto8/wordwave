# Releasing Wordwave

## Version numbers

Wordwave uses [Semantic Versioning](https://semver.org/). The version is `CFBundleShortVersionString` in
`project.yml`; bump `CFBundleVersion` (the build number) with every release.

| Change | Example | When |
|---|---|---|
| Patch | 0.1.0 → 0.1.1 | Bug fixes only. Nothing new to learn. |
| Minor | 0.1.1 → 0.2.0 | New features or settings. Existing behaviour and settings keep working. |
| Major | 0.9.0 → 1.0.0 | Something users rely on changes or goes away: a removed feature, settings reset, a higher minimum macOS. |

## Channels

- **Stable**: a normal GitHub release, marked *Latest*. Installed copies update to it by themselves, as soon as
  Wordwave is idle.
- **Beta**: a GitHub *pre-release* with a hyphenated version, such as `0.2.0-beta.1`. Never marked Latest, and
  never installed automatically: a notification announces it at most once a day, and clicking it offers
  **Install Beta**, **Not Now** (the default button) and **Skip This Beta**. Betas are offered only when no newer
  stable release verifies.

`scripts/release.sh` and `scripts/publish.sh` both run `swift scripts/update-signing.swift verify` on the ZIP, the
same check installed copies make, so a release signed with the wrong key never goes out. A published release
whose download doesn't verify is skipped by every copy for good, without ever being offered to the user.

Minor and major versions should go through at least one beta. When a beta has run for a week with no serious
bug, the same code ships as the stable version. Patch releases can skip the beta.

**Hotfixes**: a crash, data loss or security problem in the latest stable release gets a patch release as soon
as it is fixed, without waiting for anything else on `main`.

Only the latest stable release is supported; there are no fixes for older lines.

## Making a release

1. Check that CI is green on `main` and `git status` is clean.
2. In `CHANGELOG.md`, move the **Unreleased** entries under a new `## [x.y.z] - YYYY-MM-DD` heading and add its
   link at the bottom. For a beta, use `## [x.y.z-beta.n]`.
3. Set the version and build number in `project.yml`.
4. Commit: `git commit -am "Wordwave x.y.z"`. Commits are authored as the maintainer only.
5. Build: `scripts/release.sh`. It builds HEAD into `dist/`: the universal DMG, the ZIP, the ZIP's update
   signature (`Wordwave-x.y.z.zip.sig`) and `SHA256SUMS.txt`. macOS may ask once to let Terminal control Finder
   (for the DMG window) and to let `swift` use the signing key in the keychain.
6. Smoke test the DMG: install it, open it, check that a voice note gets transcribed, and that
   **⋯ ▸ Copy Diagnostic Info** shows the new version.
7. Publish: `scripts/publish.sh`. It tags `vx.y.z`, pushes the commit and the tag, and creates the GitHub release
   with the files from `dist/` and the notes from that version's `CHANGELOG.md` section. A hyphenated version
   becomes a pre-release; anything else becomes Latest.
8. If an issue is fixed in this release, comment there with the link and close it.

Release files go into a draft first and are published in one step. Don't replace the files of a published
release: installed copies may already be downloading them. A mistake is fixed with a new patch version.

## Signing

Releases are signed ad hoc and not notarized, so the first launch needs **Open Anyway** in
System Settings ▸ Privacy & Security, as the README explains. The maintainer's own certificate (in the
git-ignored `Config/Local.xcconfig`) is only for local builds: release builds never carry a team ID.

Because releases are signed ad hoc, macOS treats each version as a new app for **access to data from other
apps**: after an update it may ask once more to let Wordwave read WhatsApp's data.

## Update signing key

The in-app updater installs a release only if its ZIP comes with `Wordwave-x.y.z.zip.sig`: an Ed25519
signature, made with the release key, of

```
wordwave-update-1
com.ssquillante.Wordwave
x.y.z
<SHA-256 of Wordwave-x.y.z.zip, lowercase hex>
```

The app carries the public half as `WordwaveUpdatePublicKey` in `project.yml`, which XcodeGen copies into
Info.plist. The private half lives only in the maintainer's login keychain (item *Wordwave update signing key*),
so whoever takes over the GitHub account, the CI or the network still can't ship an update. A build without the
public key never updates itself, and `scripts/release.sh` and `scripts/publish.sh` refuse to package it.

**Back the key up offline**, for example in a password manager, by running this yourself in Terminal:
`swift scripts/update-signing.swift export`. Never commit it, paste it in an issue, or give it to CI or to an
assistant.

**On another Mac**: `swift scripts/update-signing.swift import`, then paste the backed-up key.

**If the key is lost**, copies already installed can't be updated automatically any more: run
`swift scripts/update-signing.swift generate` again (after deleting the old keychain item), release, and tell
users in the release notes and Discussions to download that version by hand once.

**If the key leaks**, whoever holds it can sign an update; they would still need to publish it as a release of
this repository, since that is the only place the app downloads from, but don't wait for that. Rotate at once:

1. `swift scripts/update-signing.swift rotate`: a new key goes into the keychain next to the current one, and its
   public half into `project.yml`. Commit it.
2. Release a patch version as usual. It is signed with the current key, so installed copies accept it, and it
   carries the new public key, so from then on they trust only the new one.
3. `swift scripts/update-signing.swift finish-rotation`: the new key becomes the signing key. Back it up.
4. Announce it as a security fix.

Version 0.1.0 is the first with the updater: people on 0.0.1 install it by hand once; after that, updates arrive
by themselves.
