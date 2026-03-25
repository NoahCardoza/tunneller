#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="Tunneller"
BUILD_DIR="$PROJECT_DIR/build"

echo "==> Cleaning..."
xcodebuild -project "$PROJECT_DIR/Tunneller.xcodeproj" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    clean \
    SYMROOT="$BUILD_DIR" \
    -quiet

echo "==> Building..."
xcodebuild -project "$PROJECT_DIR/Tunneller.xcodeproj" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    build \
    SYMROOT="$BUILD_DIR" \
    -quiet

APP="$BUILD_DIR/Debug/Tunneller.app"

echo "==> Verifying signature..."
codesign -dvv "$APP" 2>&1 | grep -E "(Authority|TeamIdentifier|Entitlements)"

echo ""
echo "==> Built at: $APP"
echo ""

if [[ "${1:-}" == "--run" ]]; then
    echo "==> Killing old instance..."
    killall Tunneller 2>/dev/null || true
    sleep 1
    echo "==> Launching..."
    open "$APP"
fi
