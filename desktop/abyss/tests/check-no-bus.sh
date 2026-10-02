#!/bin/sh
# AbyssBSD Swift DE — no message bus, anywhere (BACKLOG D.1, PRODUCT §5.6).
#
# ADE supplies a D-Bus *bridge* for foreign applications, in Swift, and never
# runs, ships, looks for or tests with the freedesktop daemon or its tools.
# This fails the build if one comes back. A line may still NAME dbus-daemon
# when it is saying it must not be there — such lines cite PRODUCT §5.6, and
# only those pass.
#
# Usage: abyss/tests/check-no-bus.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
bad=$(grep -rnE 'dbus-daemon|dbus-run-session|dbus-send|dbus-monitor|dbus-launch|xdg-dbus-proxy' \
        de abyss Tests Package.swift 2>/dev/null \
      | grep -v '^abyss/tests/check-no-bus.sh:' \
      | grep -v '§5\.6' || true)
if [ -n "$bad" ]; then
  echo "FAIL: the freedesktop bus or its tools are back (PRODUCT §5.6 — ADE supplies a bridge, never a bus):"
  echo "$bad" | sed 's/^/  /'
  exit 1
fi
echo "ok: no dbus-daemon, dbus-send, dbus-monitor or dbus-run-session anywhere in de/, abyss/ or the tests"
