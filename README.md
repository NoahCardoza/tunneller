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
tun connect --wait           # Connect and block until VPN is up (or -w)
tun status                   # Check if VPN is connected
open tunneller://connect     # Same thing via URL scheme
```

Concurrent `tun connect --wait` callers share one connection attempt and receive
the same success or failure. A request made after that attempt finishes can retry
immediately, without clearing files or waiting through a cooldown. An attempt has
a five-minute maximum wait to cover both credential reads and Cisco automation;
all callers share that deadline. Owner process exit also fails existing waiters.
Completed results are collected after a day when no caller still needs them.

## Connection diagnostics

The app and CLI write a local JSON-lines timeline at
`~/Library/Logs/Tunneller/timeline.jsonl`. Inspect recent events with:

```bash
tail -n 100 "$HOME/Library/Logs/Tunneller/timeline.jsonl"
```

Entries include UTC timestamps, app/CLI/store component, process and parent process
IDs, CLI wait mode, URL receipt/queue/handling, owner/joiner and already-connected
paths, connection phases, and success/failure/timeout/abandoned outcomes. A
`request_id` identifies each invocation; `attempt_id` identifies its shared wait
attempt (or its local request before registration). App events also include a
`connection_id` to show requests joining the same running connection.
The app's `terminal` event reports the connection flow's result; the store's
`attempt_terminal` and waiting CLI's `terminal` events report the shared wait
result, which can already have timed out before the app finishes.

For correlation with another local tool, set `TUNNELLER_ATTEMPT_ID` when invoking
`tun`. Only a UUID or `attempt.` followed by exactly ten ASCII letters/digits is
accepted. Its opaque value becomes `correlation_id` and follows the CLI request
into the app. Other values are discarded and a local UUID is used. This ID is
never printed in normal CLI output.

Logs contain only these identifiers and fixed event/outcome codes. They do not
include credential references, secrets, OTP/authentication codes, URLs, query
strings, VPN hosts, executable paths, or command arguments. Directory/file
permissions are restricted to the current user. The current file rotates at
1 MiB, retaining `timeline.1.jsonl` and `timeline.2.jsonl` (at most 3 MiB total).
Logging uses a bounded background queue and a nonwaiting file lock; contention
or filesystem failures can drop events and never change connection behavior.
The CLI and a normally quitting app drain queued events for at most 100 ms on
exit. A forcibly killed process may leave no final event; a later wait caller
records abandoned shared attempts when it detects owner exit.

## Disclaimer

Tunneller is an independent project and is not affiliated with, endorsed by, or sponsored by Cisco Systems, Inc.

Cisco, Cisco AnyConnect, and Cisco Secure Client are registered trademarks of Cisco Systems, Inc.

This project is intended solely as a compatibility utility for users who legitimately use Cisco VPN software.
