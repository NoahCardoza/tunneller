# Tunneller

A macOS menu bar app that automates Cisco Secure Client VPN connections. It fetches your credentials (from Keychain or 1Password), generates TOTP codes, and drives the Cisco UI for you — one click to connect.

## Quick Start

```bash
./build.sh --install
```

This builds the app, copies `Tunneller.app` to `/Applications`, and installs the `tun` CLI to `~/.local/bin`. After installing, you can connect from anywhere:

```bash
tun connect
```

The CLI launches Tunneller if it's not already running, then triggers the VPN connection flow.

## Requirements

- macOS 14+
- Cisco Secure Client installed
- Accessibility permission (System Settings → Privacy & Security → Accessibility)

## Features

- **One-click VPN connect** from the macOS menu bar
- **CLI tool** (`tun connect`) to trigger connections from scripts and automation
- **TOTP generation** built-in (RFC 6238, no external authenticator needed)
- **Credential sources**: macOS Keychain (biometric-protected) or 1Password CLI
- **Launch at login** support

## Build Options

```bash
./build.sh              # Build only
./build.sh --run        # Build and launch
./build.sh --install    # Build, install to /Applications, symlink CLI
```

## CLI Usage

```bash
tun connect                  # Trigger VPN connection
open tunneller://connect     # Same thing via URL scheme
```

## Disclaimer

Tunneller is an independent project and is not affiliated with, endorsed by, or sponsored by Cisco Systems, Inc.

Cisco, Cisco AnyConnect, and Cisco Secure Client are registered trademarks of Cisco Systems, Inc.

This project is intended solely as a compatibility utility for users who legitimately use Cisco VPN software.
