#!/bin/sh
# AbyssBSD Swift DE — the portal tells foreign toolkits the loaded theme (P11.10).
#
# GTK and Qt ask org.freedesktop.portal.Settings how the desktop looks —
# color-scheme, accent-color, contrast — and until P11.10 abyss-dbus answered
# Aqua's values in literals whatever the theme was. It now runs
# `abyss-theme palette` and answers from the theme that is loaded, with the
# palette's colours beside it (org.abyssbsd.palette).
#
# Asserted over a real bus, as a toolkit would ask: Aqua says light and its
# blue; Trench says dark and its magenta; Trench's neon-hc says high contrast
# because its text measures 7:1, not because of its name.
#
# Usage: abyss/tests/live-palette.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
bridge="$root/.build/debug/abyss-dbus"
[ -x "$bridge" ] && [ -x "$root/.build/debug/abyss-theme" ] || swift build
command -v dbus-daemon >/dev/null 2>&1 && command -v gdbus >/dev/null 2>&1 \
  || { echo "SKIP: no dbus-daemon or gdbus"; exit 0; }

rundir=$(mktemp -d /tmp/abyss-palette.XXXXXX)
cleanup() {
  [ -n "${bridge_pid:-}" ] && kill "$bridge_pid" 2>/dev/null || true
  [ -s "$rundir/buspid" ] && kill "$(cat "$rundir/buspid")" 2>/dev/null || true
  rm -rf "$rundir"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
mkdir -p "$rundir/cfg"

# Our own bus, never the developer's session.
busaddr=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$rundir/buspid")
export DBUS_SESSION_BUS_ADDRESS="$busaddr"

ask() {  # ask NAMESPACE KEY
  gdbus call --session --dest org.freedesktop.portal.Desktop \
    --object-path /org/freedesktop/portal/desktop \
    --method org.freedesktop.portal.Settings.ReadOne "$1" "$2" 2>&1
}

serve() {  # serve [ENV...] — start abyss-dbus under a theme, wait for ready
  [ -n "${bridge_pid:-}" ] && { kill "$bridge_pid" 2>/dev/null; wait "$bridge_pid" 2>/dev/null || true; }
  env ABYSS_CONFIG_DIR="$rundir/cfg" "$@" "$bridge" > "$rundir/out" 2> "$rundir/err" &
  bridge_pid=$!
  i=0
  while [ $i -lt 60 ]; do grep -q '^ready' "$rundir/out" 2>/dev/null && break; sleep 0.1; i=$((i + 1)); done
  grep -q '^ready' "$rundir/out" || fail "abyss-dbus never came up: $(cat "$rundir/err")"
  grep -q "settings from the theme's palette" "$rundir/err" \
    || fail "abyss-dbus did not read the theme's palette: $(cat "$rundir/err")"
}

# --------------------------------------------------------------- Aqua
serve
cs=$(ask org.freedesktop.appearance color-scheme)
case "$cs" in *"uint32 2"*) ;; *) fail "Aqua should prefer light (2), got: $cs" ;; esac
ac=$(ask org.freedesktop.appearance accent-color)
case "$ac" in *"0.247"*"0.435"*"0.874"*) ;; *) fail "Aqua's accent should be its menu blue, got: $ac" ;; esac
echo "ok: Aqua — prefer light, accent $ac"

# ------------------------------------------------------------- Trench
serve ABYSS_THEME=trench
cs=$(ask org.freedesktop.appearance color-scheme)
case "$cs" in *"uint32 1"*) ;; *) fail "Trench should prefer dark (1), got: $cs" ;; esac
ac=$(ask org.freedesktop.appearance accent-color)
case "$ac" in *"(1.0, 0.168"*"0.839"*) ;; *) fail "Trench's accent should be its magenta, got: $ac" ;; esac
ct=$(ask org.freedesktop.appearance contrast)
case "$ct" in *"uint32 0"*) ;; *) fail "neon is not high contrast, got: $ct" ;; esac
bg=$(ask org.abyssbsd.palette window-background)
case "$bg" in *"0.105"*"0.082"*"0.207"*) ;; *) fail "the palette's window background should be neon's panel, got: $bg" ;; esac
echo "ok: Trench — prefer dark, accent magenta, the palette beside it ($bg)"

serve ABYSS_THEME=trench ABYSS_THEME_SCHEME=neon-hc
ct=$(ask org.freedesktop.appearance contrast)
case "$ct" in *"uint32 1"*) ;; *) fail "neon-hc measures 7:1 and should say high contrast, got: $ct" ;; esac
echo "ok: Trench neon-hc — high contrast, because its text measures it"

echo "all green (a foreign toolkit is told the theme that is loaded)."
