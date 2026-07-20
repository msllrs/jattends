#!/usr/bin/env bash
# build.sh — Build Jattends and assemble .app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/.build"
APP_DIR="${BUILD_DIR}/Jattends.app"

cd "$PROJECT_DIR"

echo "Building Jattends..."
swift build -c release 2>&1

BINARY="${BUILD_DIR}/release/Jattends"
if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed — binary not found at $BINARY"
    exit 1
fi

echo "Assembling .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/Jattends"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Prefer a stable signing identity: macOS ties Accessibility grants to the
# code identity, and ad-hoc signatures change on every build — which silently
# revokes the grant and breaks window activation until re-granted.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' \
    | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" "$APP_DIR"
else
    echo "Signing (ad-hoc — Accessibility grant will not survive rebuilds)..."
    codesign --force --sign - "$APP_DIR"
fi

echo ""
echo "Built: $APP_DIR"
echo "Run:   open $APP_DIR"
