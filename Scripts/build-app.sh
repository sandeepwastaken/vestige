#!/bin/bash
#
# build-app.sh — compile Vestige and assemble a runnable .app bundle.
#
# Vestige ships as a SwiftPM package rather than an .xcodeproj so that it builds
# with nothing but the Xcode Command Line Tools. SwiftPM produces a bare Mach-O
# executable, so this script wraps it in the bundle structure macOS needs:
# an Info.plist (for the bundle identifier, LSUIElement, and version), an icon,
# and a code signature.
#
# The app is installed to /Applications by default. Screen Recording permission
# is remembered per app identity, and macOS treats a bundle that moves around
# as a different app, so keeping one canonical location avoids re-granting the
# permission every time and avoids duplicate entries in System Settings.
#
# Usage:
#   ./Scripts/build-app.sh                       # build and install to /Applications
#   ./Scripts/build-app.sh --run                 # build, install, then launch
#   ./Scripts/build-app.sh --no-install          # leave it in dist/ only
#   ./Scripts/build-app.sh --debug               # debug build
#   ./Scripts/build-app.sh --sign "Signing Identity Name"
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="release"
LAUNCH=0
INSTALL=1
INSTALL_DIR="/Applications"
SIGNING_IDENTITY="${VESTIGE_SIGNING_IDENTITY:-}"
FORCE_ADHOC=0

while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --debug) CONFIGURATION="debug" ;;
        --release) CONFIGURATION="release" ;;
        --run) LAUNCH=1 ;;
        --no-install) INSTALL=0 ;;
        --ad-hoc) FORCE_ADHOC=1 ;;
        --sign)
            shift
            if [ "$#" -eq 0 ]; then
                echo "error: --sign requires a code-signing identity" >&2
                exit 1
            fi
            SIGNING_IDENTITY="$1"
            ;;
        --sign=*)
            SIGNING_IDENTITY="${arg#--sign=}"
            ;;
        -h|--help)
            sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
    shift
done

APP_NAME="Vestige"
BUNDLE_ID="app.vestige.Vestige"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building ($CONFIGURATION)"
swift build --configuration "$CONFIGURATION"
BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon is generated rather than checked in as a binary blob, so the whole
# repository stays reviewable as text. See Scripts/make-icon.sh.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif [ -x "$ROOT/Scripts/make-icon.sh" ]; then
    echo "==> Generating app icon"
    "$ROOT/Scripts/make-icon.sh" >/dev/null 2>&1 || echo "    (icon generation skipped)"
    [ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Menu bar glyph. Both scales are copied so NSImage(named:) can pick the right
# one for the display it lands on.
for icon in MenuBarIcon.png MenuBarIcon@2x.png; do
    [ -f "$ROOT/Resources/$icon" ] && cp "$ROOT/Resources/$icon" "$APP/Contents/Resources/$icon"
done

# Screen Recording permission is granted to a *code requirement*, not to a path.
# Builds prefer the local identity from make-signing-cert.sh so TCC permissions
# survive rebuilds. If no identity exists, the script falls back to ad-hoc
# signing and macOS may ask for Screen Recording again after each rebuild.
LOCAL_IDENTITY="Vestige Local Signing"

IDENTITY=""
HARDENED=0
SIGN_ADHOC=0

if [ "$FORCE_ADHOC" -eq 1 ]; then
    SIGN_ADHOC=1
elif [ -n "$SIGNING_IDENTITY" ]; then
    IDENTITY="$SIGNING_IDENTITY"
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$IDENTITY\"" >/dev/null; then
        echo "error: signing identity not found: $IDENTITY" >&2
        echo "       Run: security find-identity -v -p codesigning" >&2
        exit 1
    fi
    case "$IDENTITY" in
        "Developer ID Application:"*) HARDENED=1 ;;
        *)
            echo "warning: '$IDENTITY' is not an Apple Developer ID identity." >&2
            echo "         macOS may not treat the app as a trusted download." >&2
            ;;
    esac
elif security find-identity -p codesigning 2>/dev/null | grep -F "$LOCAL_IDENTITY" >/dev/null; then
    IDENTITY="$LOCAL_IDENTITY"
else
    SIGN_ADHOC=1
fi

if [ "$SIGN_ADHOC" -eq 0 ]; then
    echo "==> Signing with: $IDENTITY"
    if [ "$HARDENED" -eq 1 ]; then
        codesign --force --options runtime --timestamp \
            --entitlements "$ROOT/Resources/Vestige.entitlements" \
            --sign "$IDENTITY" "$APP"
    else
        codesign --force \
            --entitlements "$ROOT/Resources/Vestige.entitlements" \
            --identifier "$BUNDLE_ID" \
            --sign "$IDENTITY" "$APP"
    fi
else
    echo "==> Signing ad-hoc (no signing identity found)"
    echo "    macOS will re-ask for Screen Recording access after every rebuild."
    echo "    Run ./Scripts/make-signing-cert.sh once to stop that."
    codesign --force \
        --entitlements "$ROOT/Resources/Vestige.entitlements" \
        --identifier "$BUNDLE_ID" \
        --sign - "$APP"
fi

# Show what macOS will actually remember this build as.
echo "==> Code requirement:"
codesign -d -r- "$APP" 2>&1 | grep "designated" | sed 's/^/    /'

codesign --verify --deep --strict "$APP"
echo "==> Built $APP"

TARGET="$APP"

if [ "$INSTALL" -eq 1 ]; then
    INSTALLED="$INSTALL_DIR/$APP_NAME.app"
    echo "==> Installing to $INSTALLED"

    # The app must not be running while it is replaced, or the old binary keeps
    # executing from a bundle that no longer exists on disk.
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1

    if ! rm -rf "$INSTALLED" 2>/dev/null; then
        echo "    Need administrator access to write to $INSTALL_DIR"
        sudo rm -rf "$INSTALLED"
    fi

    if ! cp -R "$APP" "$INSTALLED" 2>/dev/null; then
        sudo cp -R "$APP" "$INSTALLED"
        sudo chown -R "$(id -u):$(id -g)" "$INSTALLED"
    fi

    # Nudge Launch Services so the app appears in Spotlight and Finder at once
    # rather than whenever the system next rescans.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$INSTALLED" 2>/dev/null || true

    TARGET="$INSTALLED"
    echo "==> Installed $INSTALLED"
fi

if [ "$LAUNCH" -eq 1 ]; then
    echo "==> Launching"
    pkill -x "$APP_NAME" 2>/dev/null || true
    open "$TARGET"
fi
