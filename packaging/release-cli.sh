#!/bin/bash
# Build, sign, notarize and package the CLI for a GitHub release.
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=tydo-notary \
#   packaging/release-cli.sh
#
# One-time setup for NOTARY_PROFILE (App Store Connect API key, not an
# app-specific password — it does not expire with your Apple ID):
#   xcrun notarytool store-credentials tydo-notary \
#     --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPER_ID:?set DEVELOPER_ID to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

version=$(swift run -c release tydo version | sed -n 's/.*"cli" *: *"\([^"]*\)".*/\1/p')
[ -n "$version" ] || { echo "could not read the CLI version" >&2; exit 1; }
out="dist/tydo-$version-macos-universal.tar.gz"

echo "==> building $version (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --product tydo

echo "==> signing"
# Hardened runtime and a secure timestamp are both required for notarization.
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" .build/apple/Products/Release/tydo
codesign --verify --strict --verbose=2 .build/apple/Products/Release/tydo

echo "==> notarizing"
mkdir -p dist
ditto -c -k --keepParent .build/apple/Products/Release/tydo dist/notarize.zip
xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
rm dist/notarize.zip
# ponytail: no `stapler staple` — it only works on .app/.dmg/.pkg, never on a
# bare Mach-O. Homebrew does not quarantine formula downloads, so the online
# check is enough. Ship a .pkg instead if offline verification ever matters.

echo "==> packaging $out"
tar -czf "$out" -C .build/apple/Products/Release tydo

echo
echo "$out"
shasum -a 256 "$out"
echo
echo "Next: upload to the v$version release, then put that sha256 in"
echo "the tap's Formula/tydo.rb alongside the new url."
