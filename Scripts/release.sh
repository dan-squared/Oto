#!/usr/bin/env bash
# Build an ad-hoc-signed Oto release, zip it, and generate a signed appcast.
# No notarization: testers right-click the zip's app → Open.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD="$ROOT/build/release"
UPDATES="$ROOT/updates"
SITE_APPCAST="$ROOT/site/public/appcast.xml"
mkdir -p "$BUILD" "$UPDATES"

FEED_URL="${OTO_FEED_URL:-$(awk '/OTO_FEED_URL = / {gsub(/[;"]/, "", $3); print $3; exit}' Oto.xcodeproj/project.pbxproj)}"
if [[ -z "$FEED_URL" || "$FEED_URL" == *example.com* ]]; then
  echo "ERROR: set OTO_FEED_URL to your real HTTPS appcast URL before releasing." >&2
  echo "  export OTO_FEED_URL='https://YOUR_DOMAIN/appcast.xml'" >&2
  exit 1
fi
if grep -q 'REPLACE_WITH_SPARKLE_PUBLIC_KEY' Oto.xcodeproj/project.pbxproj; then
  echo "ERROR: SUPublicEDKey is a placeholder." >&2
  exit 1
fi

VERSION="$(awk '/MARKETING_VERSION = / {gsub(/;/, "", $3); print $3; exit}' Oto.xcodeproj/project.pbxproj)"
BUILD_NUMBER="$(awk '/CURRENT_PROJECT_VERSION = / {gsub(/;/, "", $3); print $3; exit}' Oto.xcodeproj/project.pbxproj)"
ARCHIVE="$BUILD/Oto-$VERSION-$BUILD_NUMBER.xcarchive"

echo "==> archive (ad-hoc signed, hardened runtime)"
xcodebuild archive \
  -project Oto.xcodeproj -scheme Oto -configuration Release \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES

echo "==> zip"
rm -rf "$BUILD/Oto.app"
cp -R "$ARCHIVE/Products/Applications/Oto.app" "$BUILD/Oto.app"
ZIP="$UPDATES/Oto-$VERSION-$BUILD_NUMBER.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$BUILD/Oto.app" "$ZIP"

# Sparkle tools: XPM artifacts first, then a downloaded distribution in SPARKLE_BIN.
GEN="${SPARKLE_BIN:-}/generate_appcast"
if [[ ! -x "$GEN" ]]; then
  GEN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' -type f -print -quit 2>/dev/null || true)"
fi
if [[ ! -x "$GEN" ]]; then
  echo "ERROR: generate_appcast not found. Set SPARKLE_BIN to Sparkle's bin folder." >&2
  exit 1
fi

# Keychain is the default. For CI/headless, export the seed with
# generate_keys -x and point SPARKLE_KEY_FILE at it.
KEY_ARGS=()
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
fi

# The appcast in the updates folder is the source of truth; the site copy is
# generated from it so a release never hand-edits the feed.
cp "$SITE_APPCAST" "$UPDATES/appcast.xml" 2>/dev/null || true
echo "==> generate signed appcast"
"$GEN" "$UPDATES" \
  --download-url-prefix "${OTO_DOWNLOAD_PREFIX:-https://github.com/dan-squared/Oto/releases/download/v$VERSION/}" \
  --link "https://github.com/dan-squared/Oto" \
  -o "$SITE_APPCAST" \
  ${KEY_ARGS[@]+"${KEY_ARGS[@]}"}

echo
echo "Release artifacts:"
echo "  app:     $BUILD/Oto.app"
echo "  zip:     $ZIP"
echo "  appcast: $SITE_APPCAST"
echo "  feed:    $FEED_URL"
echo
echo "Upload the zip to the matching GitHub release and commit site/public/appcast.xml,"
echo "then deploy the site. Keep the EdDSA private key safe."
