#!/bin/zsh
# Build Wordwave and (re)launch it.
#   scripts/run.sh          Release build, installed to ~/Applications (launch at login works from there)
#   scripts/run.sh --debug  Debug build from build/, with the panel shown in a preview window
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
  installed="$HOME/Applications/Wordwave.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$installed"
  ditto "$built" "$installed"
  open "$installed"
  echo "Installed $installed"
else
  open "$built" --args --preview-window
fi
