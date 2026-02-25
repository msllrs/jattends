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

echo "Signing (ad-hoc)..."
codesign --force --sign - "$APP_DIR"

echo ""
echo "Built: $APP_DIR"
echo "Run:   open $APP_DIR"
