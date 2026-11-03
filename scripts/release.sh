#!/bin/zsh
# Build the release files of Wordwave from a committed revision (universal, ad-hoc signed):
#   dist/Wordwave-<version>.dmg       drag-to-install disk image, for people
#   dist/Wordwave-<version>.zip       the same app, for the in-app updater
#   dist/Wordwave-<version>.zip.sig   the release key's signature of the zip (scripts/update-signing.swift)
#   dist/SHA256SUMS.txt
#
#   scripts/release.sh           package HEAD
#   scripts/release.sh v0.1.0    package a tag
# The app is built from the revision; the DMG window background comes from the working tree
# (Branding/dmg-background.tiff). The first run asks for permission to control Finder, which lays out the
# DMG window, and macOS may ask once to let `swift` use the signing key in the keychain.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${1:-HEAD}"
version=$(git -C "$root" show "$ref:project.yml" | awk -F'"' '/CFBundleShortVersionString/ { print $2 }')
work=$(mktemp -d)
mount=""

cleanup() {
  if [[ -n "$mount" ]]; then hdiutil detach "$mount" -quiet -force 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

echo "Building Wordwave $version from $ref…"
mkdir -p "$work/src"
git -C "$root" archive "$ref" | tar -x -C "$work/src"
(
  cd "$work/src"
  xcodegen generate --quiet
  xcodebuild -project Wordwave.xcodeproj -scheme Wordwave -configuration Release \
    -derivedDataPath "$work/build" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build
)
app="$work/build/Build/Products/Release/Wordwave.app"
codesign --verify --deep --strict "$app"
# Without the release key's public half, this version could never update itself.
[[ -n "$(plutil -extract WordwaveUpdatePublicKey raw "$app/Contents/Info.plist" 2>/dev/null)" ]] ||
  { echo "error: the app has no WordwaveUpdatePublicKey: see docs/RELEASING.md" >&2; exit 1; }

stage="$work/stage"
mkdir -p "$stage/.background"
ditto --norsrc --noextattr "$app" "$stage/Wordwave.app"
ln -s /Applications "$stage/Applications"
cp "$root/Branding/dmg-background.tiff" "$stage/.background/background.tiff"
cp "$app/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"

hdiutil create -quiet -volname Wordwave -srcfolder "$stage" -fs HFS+ -format UDRW -size 60m "$work/rw.dmg"
mount=$(hdiutil attach "$work/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF }')
SetFile -a C "$mount"

# Icon positions match the arrow drawn by Branding/make-dmg-background.swift.
osascript <<EOF
tell application "Finder"
  tell disk "$(basename "$mount")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 800, 548}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Wordwave.app" of container window to {160, 200}
    set position of item "Applications" of container window to {440, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
rm -rf "$mount/.fseventsd"
sync
hdiutil detach "$mount" -quiet
mount=""

dist="$root/dist"
rm -rf "$dist"
mkdir -p "$dist"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$dist/Wordwave-$version.dmg"
# No resource forks or extended attributes: other unzip tools would turn them into ._ files that break the signature.
(cd "$(dirname "$app")" && ditto -c -k --norsrc --noextattr --keepParent Wordwave.app "$dist/Wordwave-$version.zip")
(cd "$root" && swift scripts/update-signing.swift sign "$app" "$dist/Wordwave-$version.zip" &&
  swift scripts/update-signing.swift verify "$dist/Wordwave-$version.zip")
(cd "$dist" && shasum -a 256 "Wordwave-$version.dmg" "Wordwave-$version.zip" "Wordwave-$version.zip.sig" > SHA256SUMS.txt)
echo "Created in $dist:"
ls -1 "$dist"
