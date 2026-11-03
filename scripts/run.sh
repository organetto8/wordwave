#!/bin/zsh
# Build Wordwave and launch it from build/, without touching the installed copy in /Applications.
#   scripts/run.sh          Release build
#   scripts/run.sh --debug  Debug build, with the panel also shown in a preview window
# Any running Wordwave, including the installed one, is quit first: only one instance should watch WhatsApp.
# To install, use the DMG from scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

config=Release
[[ "${1:-}" == "--debug" ]] && config=Debug

xcodegen generate --quiet
xcodebuild -project Wordwave.xcodeproj -scheme Wordwave -configuration "$config" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build -quiet build

pkill -x Wordwave 2>/dev/null || true
built="build/Build/Products/$config/Wordwave.app"

if [[ "$config" == Release ]]; then
  open "$built"
else
  open "$built" --args --preview-window
fi
