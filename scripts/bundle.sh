#!/usr/bin/env bash
# Builds a release binary and wraps it in build/DevClean.app, signed with the hardened runtime
# (what notarization requires, so local builds behave like released ones).
# Pass --install to also copy it into ~/Applications.
#
# Environment:
#   DEVCLEAN_SIGN_IDENTITY  codesign identity; default "-" (ad-hoc, this Mac only)
#   DEVCLEAN_UNIVERSAL=1    build for Apple silicon and Intel
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${DEVCLEAN_SIGN_IDENTITY:--}"
arch_flags=()
if [[ "${DEVCLEAN_UNIVERSAL:-}" == "1" ]]; then
  arch_flags=(--arch arm64 --arch x86_64)
fi

swift build -c release ${arch_flags[@]+"${arch_flags[@]}"}
bin_dir="$(swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"

app="build/DevClean.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/DevClean" "$app/Contents/MacOS/DevClean"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

sign_flags=(--force --options runtime --sign "$identity")
# A secure timestamp is required for notarization but needs a real certificate.
[[ "$identity" != "-" ]] && sign_flags+=(--timestamp)
codesign "${sign_flags[@]}" "$app"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/DevClean.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Installed $HOME/Applications/DevClean.app"
else
  echo "Built $app"
fi
