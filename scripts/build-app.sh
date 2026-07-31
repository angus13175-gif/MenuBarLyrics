#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_PATH="${SWIFTPM_CACHE_PATH:-${HOME}/.swiftpm-cache}"
DIST_DIR="$PROJECT_DIR/dist"
DIST_APP="$DIST_DIR/MenuBarLyrics.app"
WORK_DIR="$(mktemp -d "${TMPDIR%/}/MenuBarLyrics-package.XXXXXX")"
BUILD_APP="$WORK_DIR/MenuBarLyrics.app"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F '"' '/"Apple Development:/{print $2; exit}')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
fi

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

swift build \
    --package-path "$PROJECT_DIR" \
    -c release \
    --cache-path "$CACHE_PATH"

BIN_DIR="$(swift build \
    --package-path "$PROJECT_DIR" \
    -c release \
    --cache-path "$CACHE_PATH" \
    --show-bin-path)"

cmake \
    -S "$PROJECT_DIR/third-party/mediaremote-adapter" \
    -B "$WORK_DIR/adapter" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.4
cmake --build "$WORK_DIR/adapter" --config Release --target MediaRemoteAdapter

mkdir -p \
    "$BUILD_APP/Contents/MacOS" \
    "$BUILD_APP/Contents/Resources" \
    "$BUILD_APP/Contents/Frameworks"

install -m 755 \
    "$BIN_DIR/MenuBarLyrics" \
    "$BUILD_APP/Contents/MacOS/MenuBarLyrics"
install -m 644 \
    "$PROJECT_DIR/third-party/mediaremote-adapter/bin/mediaremote-adapter.pl" \
    "$BUILD_APP/Contents/Resources/mediaremote-adapter.pl"
install -m 644 \
    "$PROJECT_DIR/MenuBarLyrics/Resources/ThirdPartyNotices.txt" \
    "$BUILD_APP/Contents/Resources/ThirdPartyNotices.txt"
install -m 644 \
    "$PROJECT_DIR/MenuBarLyrics/Resources/AppIcon.icns" \
    "$BUILD_APP/Contents/Resources/AppIcon.icns"
ditto --noextattr --norsrc \
    "$PROJECT_DIR/MenuBarLyrics/Resources/CatSpriteSheets" \
    "$BUILD_APP/Contents/Resources/CatSpriteSheets"
install -m 644 \
    "$PROJECT_DIR/Packaging/Info.plist" \
    "$BUILD_APP/Contents/Info.plist"
ditto --noextattr --norsrc \
    "$WORK_DIR/adapter/MediaRemoteAdapter.framework" \
    "$BUILD_APP/Contents/Frameworks/MediaRemoteAdapter.framework"

find "$BUILD_APP" -name '._*' -delete
xattr -cr "$BUILD_APP"
codesign --force --sign "$SIGN_IDENTITY" \
    "$BUILD_APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign "$SIGN_IDENTITY" "$BUILD_APP"

mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP"
ditto --noextattr --norsrc "$BUILD_APP" "$DIST_APP"
find "$DIST_APP" -name '._*' -delete
codesign --verify --deep --strict "$DIST_APP"
echo "Signed with: $SIGN_IDENTITY"

if [[ "${1:-}" == "--install" ]]; then
    # SMAppService.mainApp only resolves a stable launch-at-login registration
    # when the bundle lives in an Applications directory. Prefer the system
    # Applications folder; callers can override this for packaging tests.
    INSTALL_DIR="${MENUBARLYRICS_INSTALL_DIR:-/Applications}"
    INSTALL_APP="$INSTALL_DIR/MenuBarLyrics.app"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_APP"
    ditto --noextattr --norsrc "$DIST_APP" "$INSTALL_APP"
    find "$INSTALL_APP" -name '._*' -delete
    codesign --verify --deep --strict "$INSTALL_APP"
    LEGACY_APP="$HOME/Applications/MenuBarLyrics.app"
    if [[ "$LEGACY_APP" != "$INSTALL_APP" && -d "$LEGACY_APP" ]]; then
        rm -rf "$LEGACY_APP"
    fi
    echo "Installed: $INSTALL_APP"
else
    echo "Built: $DIST_APP"
fi
