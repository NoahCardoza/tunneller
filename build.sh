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

echo "==> Building CLI tool..."
swiftc -o "$BUILD_DIR/Debug/tunneller-cli" \
    "$PROJECT_DIR/Tunneller/CLI/tunneller-cli.swift" \
    -O
cp "$BUILD_DIR/Debug/tunneller-cli" "$APP/Contents/MacOS/tunneller-cli"

echo ""
echo "==> Built at: $APP"
echo "==> CLI tool: $APP/Contents/MacOS/tunneller-cli"
echo ""

RUN=false
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --run)     RUN=true ;;
        --install) INSTALL=true ;;
    esac
done

if $INSTALL; then
    DEST="/Applications/Tunneller.app"
    echo "==> Installing to $DEST..."
    killall Tunneller 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    CLI_DIR="$HOME/.local/bin"
    mkdir -p "$CLI_DIR"
    echo "==> Installing CLI symlink to $CLI_DIR/tun..."
    ln -sf "$DEST/Contents/MacOS/tunneller-cli" "$CLI_DIR/tun"
    echo "==> Installed."

    # Check if ~/.local/bin is in PATH
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$CLI_DIR"; then
        echo ""
        echo "NOTE: $CLI_DIR is not in your PATH."
        echo "Add it by running:"
        echo ""
        echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
        echo ""
        echo "Then you can use 'tun connect' from anywhere."
    fi
    APP="$DEST"
fi

if $RUN; then
    echo "==> Killing old instance..."
    killall Tunneller 2>/dev/null || true
    sleep 1
    echo "==> Launching..."
    open "$APP"
fi
