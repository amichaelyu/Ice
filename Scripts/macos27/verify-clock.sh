#!/bin/bash
#
# Verifies that the clock and Control Center open while Ice conceals items on macOS 27.
# Requirements: Ice installed with Scripts/install.sh, Thaw not running.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d /tmp/ice-verify-clock.XXXXXX)"
swiftc -O "$ROOT/Scripts/macos27/system-click.swift" -o "$WORK/system-click"

quit_ice() {
    osascript -e 'tell application id "com.jordanbaird.Ice" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do pgrep -x Ice >/dev/null || return 0; sleep 0.25; done
}
trap quit_ice EXIT

quit_ice
open "$HOME/Applications/Ice.app"
sleep 10

FAILED=0
if "$WORK/system-click" clock; then echo "PASS  the clock opens Notification Center while concealing"; else echo "FAIL  the clock opens Notification Center while concealing"; FAILED=1; fi
sleep 2
if "$WORK/system-click" controlcenter; then echo "PASS  Control Center opens while concealing"; else echo "FAIL  Control Center opens while concealing"; FAILED=1; fi
exit $FAILED
