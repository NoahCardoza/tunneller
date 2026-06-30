#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="Tunneller"
BUILD_DIR="$PROJECT_DIR/build"

# Self-signed certificate config
CERT_NAME="Tunneller Dev"
CERTS_DIR="$PROJECT_DIR/certs"
CERT_PEM="$CERTS_DIR/tunneller-dev.pem"
KEY_PEM="$CERTS_DIR/tunneller-dev-key.pem"
P12_FILE="$CERTS_DIR/tunneller-dev.p12"
BUILD_KEYCHAIN="tunneller-build.keychain-db"
BUILD_KEYCHAIN_PASS="tunneller-build"

setup_signing() {
    echo "==> Setting up signing certificate..."
    mkdir -p "$CERTS_DIR"

    # Generate self-signed cert + key if missing
    if [ ! -f "$CERT_PEM" ]; then
        echo "  Generating self-signed certificate (one-time)..."
        openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PEM" -out "$CERT_PEM" \
            -days 3650 -nodes \
            -subj "/CN=Tunneller Dev" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
        openssl pkcs12 -export -out "$P12_FILE" \
            -inkey "$KEY_PEM" -in "$CERT_PEM" \
            -passout pass:"$BUILD_KEYCHAIN_PASS" 2>/dev/null
        echo "  Certificate created."
    fi

    # Create the build keychain if it doesn't exist
    if ! security list-keychains | grep -q "$BUILD_KEYCHAIN"; then
        security create-keychain -p "$BUILD_KEYCHAIN_PASS" "$BUILD_KEYCHAIN"
    fi
    security unlock-keychain -p "$BUILD_KEYCHAIN_PASS" "$BUILD_KEYCHAIN"
    # Keep it unlocked for the duration of the build
    security set-keychain-settings -t 3600 -u "$BUILD_KEYCHAIN"

    # Ensure it's on the keychain search list
    security list-keychains -d user -s "$BUILD_KEYCHAIN" ~/Library/Keychains/login.keychain-db

    # Import cert + trust it if not already present
    if ! security find-certificate -c "$CERT_NAME" "$BUILD_KEYCHAIN" &>/dev/null; then
        echo "  Importing certificate into build keychain..."
        security import "$P12_FILE" -k "$BUILD_KEYCHAIN" -P "$BUILD_KEYCHAIN_PASS" \
            -T /usr/bin/codesign -T /usr/bin/security
        # Allow codesign to use the key without prompting
        security set-key-partition-list -S apple-tool:,apple: \
            -s -k "$BUILD_KEYCHAIN_PASS" "$BUILD_KEYCHAIN" 2>/dev/null
        # Trust the cert for code signing
        security add-trusted-cert -d -r trustRoot -p codeSign \
            -k "$BUILD_KEYCHAIN" "$CERT_PEM"
        echo "  Certificate imported and trusted."
    fi

    echo "==> Signing ready: $CERT_NAME"
}

setup_signing

echo "==> Cleaning..."
xcodebuild -project "$PROJECT_DIR/Tunneller.xcodeproj" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    clean \
    SYMROOT="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

echo "==> Building..."
xcodebuild -project "$PROJECT_DIR/Tunneller.xcodeproj" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    build \
    SYMROOT="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

APP="$BUILD_DIR/Debug/Tunneller.app"

echo "==> Building CLI tool..."
swiftc -o "$BUILD_DIR/Debug/tunneller-cli" \
    "$PROJECT_DIR/Tunneller/CLI/tunneller-cli.swift" \
    -O
cp "$BUILD_DIR/Debug/tunneller-cli" "$APP/Contents/MacOS/tunneller-cli"

echo "==> Signing with $CERT_NAME..."
codesign --force --deep \
    --sign "$CERT_NAME" \
    --keychain "$BUILD_KEYCHAIN" \
    --entitlements "$PROJECT_DIR/Tunneller/Tunneller.entitlements" \
    "$APP"

echo "==> Verifying signature..."
codesign -dvv "$APP" 2>&1 | grep -E "(Authority|TeamIdentifier|Identifier)"

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
    rm -rf "$DEST" || { echo "==> Permission denied, retrying with sudo..."; sudo rm -rf "$DEST"; }
    cp -R "$APP" "$DEST" || { echo "==> Permission denied, retrying with sudo..."; sudo cp -R "$APP" "$DEST"; }
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
