#!/bin/sh
# AbyssBSD Swift DE — one command boots a desktop a foreign app can use (P8.4).
#
# P8.3 proved the claim with six processes started by hand and a shell script
# holding the environment together. This proves it with **one command**:
#
#     anchor --compositor "undertow run … --socket NAME" --display NAME
#
# and nothing else. `anchor` starts the compositor, the session bus, the portal,
# the D-Bus bridge and the three shell components, in that order, and puts
# DBUS_SESSION_BUS_ADDRESS into the environment of every one of them. That is the
# whole of P8.4, and the reason it is a pass rather than a footnote is that the
# ordering is real: the bridge cannot own a name on a bus that is not listening,
# and the shell cannot connect to a compositor that has not bound its socket.
#
# What it proves, in order:
#
#   1. One command brings up **six components**, and `abyssctl` says so.
#   2. The session named its own bus — the address is inside the session's own
#      runtime directory, next to `anchor.sock` and `portal.sock`, rather than
#      whatever `dbus-daemon` felt like choosing. That is what makes it survive a
#      restart of the daemon and knowable before the daemon exists.
#   3. **A child of anchor inherited that address and used it.** `abyss-dbus`
#      owns `org.freedesktop.portal.Desktop` on the session's bus — which it
#      could only do by reading the variable anchor exported. This is the
#      assertion that the environment plumbing is real and not decorative.
#   4. A stock GTK 3 application, given only that address, gets the Finder and a
#      file it never named — the P8.3 claim, now on a session nobody assembled
#      by hand.
#   5. `abyssctl quit` takes the whole thing down: no stray `dbus-daemon`, no
#      stale sockets. A session supervisor that leaks a bus per run is worse
#      than none.
#
# Usage: abyss/tests/live-session-gtk.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

anchor="$root/.build/debug/anchor"
ctl="$root/.build/debug/abyssctl"
undertow="$root/.build/debug/undertow"
demo="$root/.build/debug/AquaDemo"
bridge="$root/.build/debug/abyss-dbus"
[ -x "$anchor" ] && [ -x "$ctl" ] && [ -x "$undertow" ] && [ -x "$demo" ] && [ -x "$bridge" ] \
  || swift build

command -v dbus-daemon >/dev/null || { echo "FAIL: dbus-daemon not installed"; exit 1; }
command -v gdbus >/dev/null || { echo "FAIL: gdbus not installed"; exit 1; }

W=900
H=700
# A socket name of our own, carrying the pid so two runs of this script (or a
# leftover from a killed one) cannot collide on it. `undertow --socket` refuses a
# name that is taken rather than quietly picking another, which is what makes
# passing the same name to `--display` safe.
sock="abyss-p84-$$"

# Short paths: a unix socket must fit in sun_path (HANDOFF §2.32).
work=$(mktemp -d /tmp/abyss-p84.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-p84r.XXXXXX)
cleanup() {
  [ -n "${fd3open:-}" ] && exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${app_pid:-} ${mon_pid:-} ${anchor_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" "$rundir" "${vp_dir:-}" "${fifo:-}" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------- the app
# Built here, dlopen'd not linked — see the header of gtkpick.c. A box with no
# GTK runtime skips loudly (exit 77) rather than passing quietly.
app="$work/gtkpick"
cc -O0 "$root/abyss/tests/gtkpick.c" -ldl -o "$app" \
  || { echo "FAIL: could not build the GTK client"; exit 1; }
set +e
"$app" --probe-only >/dev/null 2>"$work/probe.err"
probe_rc=$?
set -e
if [ "$probe_rc" = 77 ]; then
  echo "SKIP: no GTK 3 runtime on this box — $(cat "$work/probe.err")"
  exit 0
fi

# --------------------------------------------------------------- the pointer
# Compiled before the session starts, so the compositor's frame budget is spent
# on the test rather than on a compiler.
vp_dir=$(mktemp -d)
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$vp_dir/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$vp_dir/vpointer-proto.c"
cc -I"$vp_dir" "$root/abyss/tests/vpointer.c" "$vp_dir/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$vp_dir/vpointer"

# ----------------------------------------------------------------- the files
# A fixed directory name, because it becomes the Finder window's title and so
# half of its remembered-position key. A space in the chosen file's name on
# purpose: `%20` is the ordinary case, and an unescaped space makes a URI GLib
# rejects.
docs="$work/Documents"
mkdir -p "$docs"
chosen="Chosen file.txt"
secret="the gtk app never named this file $$"
printf '%s\n' "$secret" > "$docs/$chosen"
printf 'not this one\n' > "$docs/Other.txt"

cfgdir="$work/config"
mkdir -p "$cfgdir"
cat > "$cfgdir/windows.ini" <<EOF
[windows]
org.abyssbsd.finder = 0,0
org.abyssbsd.finder/Documents = 0,0
gtkpick = 560,420
gtkpick/Abyss GTK Client = 560,420
EOF

# ------------------------------------------------------------- ONE COMMAND
# `env -u DBUS_SESSION_BUS_ADDRESS` is load-bearing, not hygiene: on a developer
# box the variable is already set to the login session's bus, and a test that
# left it there could pass while anchor did nothing at all. Removing it means
# every bus in what follows is one this session made.
#
# The bus uses the system's own `--session` config, which is what a user gets.
# That config can activate services, but nothing here ever asks the bus for an
# unowned name: `abyss-dbus` takes org.freedesktop.portal.Desktop at startup and
# refuses to run if it cannot be the primary owner (P8.2), so a stock
# xdg-desktop-portal on this machine cannot quietly answer instead of us.
env -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY \
    ABYSS_RUNTIME_DIR="$rundir" ABYSS_CONFIG_DIR="$cfgdir" \
    "$anchor" \
      --compositor "$undertow run --hz 60 --frames 5400 --width $W --height $H \
                    --socket $sock --privileged-socket $sock-bar --config-dir $cfgdir" \
      --display "$sock" --menubar-display "$sock-bar" \
      > "$work/session.log" 2>&1 &
anchor_pid=$!
export ABYSS_RUNTIME_DIR="$rundir"

# --------------------------------------------------------------- 1. it is up
i=0
while [ $i -lt 200 ]; do
  "$ctl" status > "$work/status" 2>/dev/null && grep -q 'dock=up' "$work/status" && break
  kill -0 "$anchor_pid" 2>/dev/null \
    || { echo "FAIL: anchor exited during bring-up"; cat "$work/session.log"; exit 1; }
  sleep 0.25; i=$((i + 1))
done
grep -q 'dock=up' "$work/status" 2>/dev/null \
  || { echo "FAIL: the session never came up"; cat "$work/status" "$work/session.log"; exit 1; }
for c in bus portal bridge menus desktop menubar dock; do
  grep -q "$c=up" "$work/status" \
    || { echo "FAIL: $c is not up"; cat "$work/status" "$work/session.log"; exit 1; }
done
echo "ok: one command brought up bus, portal, bridge, menus, desktop, menubar and dock"

# The bar came up on the privileged socket and — with no window yet — shows the
# desktop's Finder (PHASE10 P10.4). On the ordinary socket it would say it has
# no view of focus, and every menu would be the Finder's for ever.
i=0
while [ $i -lt 40 ]; do
  grep -q "MenuBar: showing Finder's menus from menus.finder." "$work/session.log" && break
  sleep 0.25; i=$((i + 1))
done
grep -q "not on the compositor's privileged socket" "$work/session.log" \
  && { echo "FAIL: the session's menu bar is on the ordinary socket"; exit 1; }
grep -q "MenuBar: showing Finder's menus from menus.finder." "$work/session.log" \
  || { echo "FAIL: the session's menu bar never showed the desktop's Finder"
       grep 'MenuBar\|menus' "$work/session.log" | tail -5; exit 1; }
echo "ok: the menu bar is on the privileged socket, showing the desktop's Finder"

# **Nothing restarted.** This is the assertion that tells a gate from a race,
# and it is the only one here that could not be satisfied by getting the order
# right on paper: `anchor` logs "bridge up" immediately after spawning it either
# way, so line order proves nothing. A restart count of zero across all six says
# every component found what it needed *already listening* — the bridge found a
# bus, the shell found a compositor — rather than crashing into a socket that
# did not exist yet and being put back by the restart policy.
#
# Injected once by deleting the `requires` wait from Supervisor.start: a
# component came up as `up(1)` and this line failed, which is what the absence
# of the gate looks like from outside — a session that works anyway, most of the
# time, by crashing until it doesn't have to.
restarted=$(grep -o '=up([1-9][0-9]*)' "$work/status" | head -1)
[ -z "$restarted" ] \
  || { echo "FAIL: something had to be restarted to compose: $restarted"
       cat "$work/status" "$work/session.log"; exit 1; }
echo "ok: every component started once — the session composed, it did not race"

# ----------------------------------------------------- 2. the session named it
bus=$(grep '^bus: ' "$work/status" | head -1 | sed 's/^bus: //')
[ -n "$bus" ] \
  || { echo "FAIL: abyssctl did not report a bus address"; cat "$work/status"; exit 1; }
[ "$bus" = "unix:path=$rundir/bus" ] \
  || { echo "FAIL: the bus is not where the session put it"
       echo "      wanted unix:path=$rundir/bus, got $bus"; exit 1; }
[ -S "$rundir/bus" ] \
  || { echo "FAIL: no bus socket in the session's runtime dir"; ls -la "$rundir"; exit 1; }
echo "ok: the session named its own bus ($bus)"

# --------------------------------------------- 3. a child inherited and used it
# The bridge could only own that name by reading the variable anchor exported
# before spawning it. Nothing else in this test sets it for that process.
owner=$(DBUS_SESSION_BUS_ADDRESS="$bus" gdbus call --session --timeout 5 \
        --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetNameOwner org.freedesktop.portal.Desktop 2>&1)
case "$owner" in
  *:1.*) echo "ok: abyss-dbus inherited DBUS_SESSION_BUS_ADDRESS and owns the portal name" ;;
  *) echo "FAIL: nobody owns the portal name on the session bus: $owner"
     cat "$work/session.log"; exit 1 ;;
esac

# ------------------------------------------------------------- 4. a real app
# An independent decoder watching the same bus (HANDOFF §2.40 — a real monitor,
# because the Response is addressed to its caller and match rules cannot see it).
if command -v dbus-monitor >/dev/null; then
  DBUS_SESSION_BUS_ADDRESS="$bus" dbus-monitor --session > "$work/monitor" 2>&1 &
  mon_pid=$!
fi

export WAYLAND_DISPLAY="$sock"
fifo="$work/vp.fifo"
mkfifo "$fifo"
"$vp_dir/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3>"$fifo"
fd3open=1
for _ in $(seq 1 30); do grep -q ready "$work/vp.log" && break; sleep 0.15; done
grep -q ready "$work/vp.log" \
  || { echo "FAIL: virtual pointer not ready on the session's compositor"
       cat "$work/vp.log"; exit 1; }

# The app gets the bus address and nothing else about this desktop — the same
# thing it would inherit from the Dock that launched it.
env GTK_USE_PORTAL=1 GTK_A11Y=none GDK_BACKEND=wayland \
    DBUS_SESSION_BUS_ADDRESS="$bus" \
    "$app" "$docs" > "$work/app.out" 2>"$work/app.err" &
app_pid=$!

i=0
while [ $i -lt 80 ]; do grep -q 'window up' "$work/app.err" 2>/dev/null && break; sleep 0.25; i=$((i+1)); done
grep -q 'window up' "$work/app.err" \
  || { echo "FAIL: the GTK app never mapped a window on the session's compositor"
       cat "$work/app.err" "$work/session.log"; exit 1; }

i=0
while [ $i -lt 120 ]; do
  grep -q 'Finder: listed' "$work/session.log" 2>/dev/null && break
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 0.25; i=$((i + 1))
done
grep -q 'Finder: listed' "$work/session.log" \
  || { echo "FAIL: GtkFileChooserNative did not open the Finder"
       echo "-- app"; cat "$work/app.err"
       echo "-- session"; cat "$work/session.log"; exit 1; }
echo "ok: a stock GTK app on this session opened the Finder"

# The Finder is seeded at 0,0. The seeded dir sorts to "Chosen file.txt",
# "Other.txt"; cell 1 of a 5-column grid of 88px cells from x=10, icons centred
# at y=96 → x=54. Same arithmetic as live-gtk.sh, same picker.
sleep 1.0
printf 'm 54 96\np\nr\np\nr\n' >&3
sleep 2.5

i=0
while [ $i -lt 150 ]; do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
kill -0 "$app_pid" 2>/dev/null \
  && { echo "FAIL: the GTK app is still waiting — it never got its Response"
       cat "$work/app.err" "$work/session.log"; exit 1; }
rc=0; wait "$app_pid" 2>/dev/null || rc=$?
app_pid=""
[ "$rc" = 0 ] || { echo "FAIL: the GTK app exited $rc"
                   cat "$work/app.out" "$work/app.err" "$work/session.log"; exit 1; }

want="file://$docs/Chosen%20file.txt"
grep -q "^uri=$want\$" "$work/app.out" \
  || { echo "FAIL: wrong uri (wanted $want)"; cat "$work/app.out"; exit 1; }
grep -q "^contents=$secret\$" "$work/app.out" \
  || { echo "FAIL: the app did not read the chosen file"; cat "$work/app.out"; exit 1; }
grep -q "$chosen" "$work/app.err" \
  && { echo "FAIL: the app named the file itself somewhere"; cat "$work/app.err"; exit 1; }
echo "ok: it was handed, and read, a file it never named (it named a directory)"

if [ -n "${mon_pid:-}" ]; then
  grep -E 'destination=:[0-9.]+.*member=Response' "$work/monitor" >/dev/null \
    || { echo "FAIL: no addressed Response on the session bus"
         grep Response "$work/monitor"; exit 1; }
  echo "ok: libdbus saw the Response go past, addressed to the app"
  kill "$mon_pid" 2>/dev/null || true; mon_pid=""
fi

# ------------------------------------------------------- 5. and it goes away
exec 3>&-; fd3open=""
kill "$vp_pid" 2>/dev/null || true; vp_pid=""

"$ctl" quit > "$work/quit" 2>&1 \
  || { echo "FAIL: abyssctl quit failed"; cat "$work/quit"; exit 1; }
i=0
while [ $i -lt 100 ]; do kill -0 "$anchor_pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
kill -0 "$anchor_pid" 2>/dev/null \
  && { echo "FAIL: anchor ignored quit"; cat "$work/session.log"; exit 1; }
anchor_pid=""

# **Processes, first.** A supervisor that leaks a bus per session is worse than
# one that starts none, because the leak is invisible until the machine runs out
# of sockets — and `dbus-daemon` is the one child here that would happily outlive
# its parent.
sleep 0.5
pgrep -f "address=unix:path=$rundir/bus" >/dev/null 2>&1 \
  && { echo "FAIL: the session's dbus-daemon outlived the session"
       pgrep -af "address=unix:path=$rundir/bus"; exit 1; }
pgrep -f "ABYSS_RUNTIME_DIR=$rundir" >/dev/null 2>&1 \
  && { echo "FAIL: a supervised child outlived the session"
       pgrep -af "$rundir"; exit 1; }
[ -e "$rundir/anchor.sock" ] \
  && { echo "FAIL: the control socket outlived the session"; exit 1; }
echo "ok: quit took the whole session down — no stray bus, no orphans"

# The compositor's socket file IS left behind, and that is not asserted away
# here because it would be a false claim: `undertow` has no signal handler, so
# SIGTERM ends it without reaching `wl_display_destroy`, which is what unlinks
# the socket. Measured rather than assumed: a second session binding the same
# name over the leftover succeeds — libwayland's lock file, not the socket file,
# is what decides — so the leftover is litter and not a lock. Giving `undertow`
# a clean shutdown is worth doing (it would also let a test read its end-of-run
# summary without spending the whole frame budget), and it is Phase 6's, not
# this pass's.

echo "all green (one command, and a foreign app got its file)."
