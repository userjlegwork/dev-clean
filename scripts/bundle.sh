#!/usr/bin/env bash
# Builds a release binary and wraps it in build/DevClean.app (ad-hoc signed).
# Pass --install to also copy it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"

app="build/DevClean.app"
rm -rf "build/DevClean.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/DevClean" "$app/Contents/MacOS/DevClean"
cp Support/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/DevClean.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Installed $HOME/Applications/DevClean.app"
else
  echo "Built $app"
fi
