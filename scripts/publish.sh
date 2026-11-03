#!/bin/zsh
# Publishes the files scripts/release.sh left in dist/ as a GitHub release for the version in project.yml.
# The notes are that version's section of CHANGELOG.md followed by the install instructions.
# A hyphenated version (0.2.0-beta.1) becomes a pre-release; anything else becomes Latest.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(awk -F'"' '/CFBundleShortVersionString/ { print $2 }' project.yml)"
TAG="v$VERSION"
FILES=("dist/Wordwave-$VERSION.dmg" "dist/Wordwave-$VERSION.zip" "dist/Wordwave-$VERSION.zip.sig" "dist/SHA256SUMS.txt")

fail() { echo "error: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || fail "commit or stash your changes first"
[[ "$(git config user.email)" == "stefano.squillante7423@gmail.com" ]] || fail "git user.email must be stefano.squillante7423@gmail.com in this repository"
for file in "${FILES[@]}"; do [[ -f "$file" ]] || fail "$file is missing: run scripts/release.sh"; done
plist="$(mktemp)"
trap 'rm -f "$plist"' EXIT
unzip -p "dist/Wordwave-$VERSION.zip" Wordwave.app/Contents/Info.plist > "$plist"
built="$(plutil -extract CFBundleShortVersionString raw "$plist")"
[[ "$built" == "$VERSION" ]] || fail "dist/ holds Wordwave $built, project.yml says $VERSION: run scripts/release.sh"
[[ -n "$(plutil -extract WordwaveUpdatePublicKey raw "$plist" 2>/dev/null)" ]] ||
  fail "the app has no WordwaveUpdatePublicKey: see docs/RELEASING.md"
# A wrong signature would make every installed copy refuse this release: check it the way they will.
swift scripts/update-signing.swift verify "dist/Wordwave-$VERSION.zip" || fail "the update signature doesn't verify"
gh release view "$TAG" >/dev/null 2>&1 && fail "release $TAG already exists"

# The lines between "## [VERSION]" and the next heading or link reference.
changes="$(awk -v heading="## [$VERSION]" '
    index($0, heading) == 1 { found = 1; next }
    found && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    found { print }
' CHANGELOG.md | sed -e '/./,$!d')"
[[ -n "$changes" ]] || fail "CHANGELOG.md has no section for $VERSION"

notes="$changes

## Install

1. Download **Wordwave-$VERSION.dmg** below.
2. Open it and drag **Wordwave** onto **Applications** (replace the old version if asked).
3. Open Wordwave. The app is not notarized, so the first time macOS blocks it: go to
   **System Settings ▸ Privacy & Security** and click **Open Anyway**.
4. When macOS asks to let Wordwave access data from other apps, choose **Allow**.

From 0.1.0 on, Wordwave installs new stable versions by itself and asks before installing a beta.
Requires macOS 26 or later and WhatsApp Desktop for Mac. Universal build for Apple silicon and Intel.
All changes: [CHANGELOG](https://github.com/organetto8/wordwave/blob/main/CHANGELOG.md).

## Checksums (SHA-256)

\`\`\`
$(cat dist/SHA256SUMS.txt)
\`\`\`"

flags=(--title "Wordwave $VERSION" --verify-tag)
publish=(--draft=false)
if [[ "$VERSION" == *-* ]]; then flags+=(--prerelease); else publish+=(--latest); fi

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Wordwave $VERSION"
git push origin HEAD "refs/tags/$TAG"
# Releases are immutable once published, so the files go into a draft first.
printf '%s\n' "$notes" | gh release create "$TAG" --draft "${flags[@]}" --notes-file - "${FILES[@]}"
gh release edit "$TAG" "${publish[@]}"
echo "Published https://github.com/organetto8/wordwave/releases/tag/$TAG"
