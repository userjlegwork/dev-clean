#!/usr/bin/env bash
# Builds a universal DevClean, signs it with Developer ID, notarizes and staples it, and wraps it in
# build/DevClean-<version>.dmg that opens on any Mac without Gatekeeper warnings.
#
#   scripts/release.sh --check           only report whether signing and notarizing are set up
#   scripts/release.sh --skip-notarize   sign and package without submitting to Apple (for testing)
#   scripts/release.sh                   full release
#
# One-time setup (see README, "Releasing"):
#   1. A "Developer ID Application" certificate in the login keychain (Apple Developer Program).
#   2. Notary credentials stored in the keychain:
#        xcrun notarytool store-credentials devclean --apple-id <you> --team-id <TEAMID>
#      (prompts for an app-specific password from account.apple.com).
#
# Environment:
#   DEVCLEAN_SIGN_IDENTITY   override the certificate (default: the first Developer ID Application one)
#   DEVCLEAN_NOTARY_PROFILE  keychain profile name (default: devclean)
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-release}"
profile="${DEVCLEAN_NOTARY_PROFILE:-devclean}"
identity="${DEVCLEAN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"

ready=1
if [[ -n "$identity" ]]; then
  echo "✔ Signing identity: $identity"
else
  echo "✘ No \"Developer ID Application\" certificate in the keychain."
  echo "  Create one at developer.apple.com → Certificates (needs the Apple Developer Program), then open it to install."
  ready=0
fi
if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
  echo "✔ Notary profile: $profile"
else
  echo "✘ No notary credentials in keychain profile \"$profile\"."
  echo "  Run: xcrun notarytool store-credentials $profile --apple-id <apple id> --team-id <team id>"
  [[ "$mode" != "--skip-notarize" ]] && ready=0
fi

if [[ "$mode" == "--check" ]]; then
  [[ $ready == 1 ]] && echo "Ready to release $version." || echo "Not ready yet."
  exit $(( 1 - ready ))
fi
if [[ "$mode" == "--skip-notarize" && -z "$identity" ]]; then
  echo "No Developer ID: signing ad-hoc to test packaging only (this DMG works on this Mac only)."
  identity="-"
elif [[ $ready == 0 ]]; then
  exit 1
fi

DEVCLEAN_SIGN_IDENTITY="$identity" DEVCLEAN_UNIVERSAL=1 scripts/bundle.sh
app="build/DevClean.app"
codesign --verify --strict --deep "$app"

notarize() {
  echo "Submitting $1 to Apple (usually a few minutes)…"
  xcrun notarytool submit "$1" --keychain-profile "$profile" --wait
  xcrun stapler staple "$2"
}

if [[ "$mode" != "--skip-notarize" ]]; then
  # Notarize and staple the app itself, so it also opens offline once copied out of the DMG.
  zip="build/DevClean-$version.zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip" "$app"
  rm "$zip"
fi

dmg="build/DevClean-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "DevClean $version" -srcfolder "$staging" -ov -format UDZO "$dmg"
dmg_flags=(--force --sign "$identity")
[[ "$identity" != "-" ]] && dmg_flags+=(--timestamp)
codesign "${dmg_flags[@]}" "$dmg"

if [[ "$mode" != "--skip-notarize" ]]; then
  notarize "$dmg" "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
  spctl --assess --type execute --verbose "$app"
fi
echo "Built $dmg"
