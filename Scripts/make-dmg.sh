#!/bin/bash
#
# make-dmg.sh — package the locally built app into an unnotarized DMG.
#
# Usage:
#   ./Scripts/build-app.sh --no-install --ad-hoc
#   ./Scripts/make-dmg.sh
#
# This creates downloads/Vestige-<version>-unnotarized.dmg for GitHub users who
# want an easy download. It is intentionally not notarized; macOS will show the
# normal unidentified-developer warning.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Vestige"
APP="$ROOT/dist/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DOWNLOADS="$ROOT/downloads"
DMG="$DOWNLOADS/$APP_NAME-$VERSION-unnotarized.dmg"
STAGING="$ROOT/dist/dmg-staging"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run ./Scripts/build-app.sh --no-install --ad-hoc first" >&2
    exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING" "$DOWNLOADS"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "==> Built $DMG"
