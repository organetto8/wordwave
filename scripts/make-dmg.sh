#!/bin/zsh
# Build a drag-to-install DMG of Wordwave from a committed revision (universal, ad-hoc signed).
#   scripts/make-dmg.sh           package HEAD
#   scripts/make-dmg.sh v0.0.1    package a tag
# Output: dist/Wordwave-<version>.dmg and its .sha256. The app is built from the revision;
# the window background comes from the working tree (Branding/dmg-background.tiff).
# The first run asks for permission to control Finder, which lays out the DMG window.
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

mkdir -p "$root/dist"
out="$root/dist/Wordwave-$version.dmg"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$out"
(cd "$root/dist" && shasum -a 256 "Wordwave-$version.dmg" > "Wordwave-$version.dmg.sha256")
echo "Created $out"
