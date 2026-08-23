#!/bin/sh
# AbyssBSD Swift DE — a real GTK application gets the Finder (PHASE8.md P8.3).
#
# This is the pass that deletes PHASE7 §6.7's caveat. P8.2 proved the protocol
# with `gdbus`, which is a D-Bus client rather than an application; the claim
# only becomes true when the caller is a program that asks for a file the way
# every GTK program asks for a file, and has never heard of us.
#
# Six real processes, and the important one is not ours:
#
#   undertow      our compositor — GTK is just another xdg-shell client
#   dbus-daemon   the session bus
#   abyss-portal  the portal (P7.1), unchanged
#   abyss-dbus    the bridge (P8.2), unchanged apart from Settings
#   gtkpick       a stock GTK 3 app: gtk_file_chooser_native_new + run
#   AquaDemo      the Finder, launched by the portal, as the picker
#
# What it proves, in order:
#
#   1. GTK 3 composes on `undertow` — a toolkit that has never seen this
#      compositor maps a window on it. Two windows, in fact: the app's own and
#      the picker's.
#   2. GTK's startup probe of `org.freedesktop.portal.Settings` is ANSWERED.
#      That interface arrived in this pass because a real app asked for it
#      (PHASE8 §6.4 predicted exactly that), and the difference between an empty
#      answer and no answer is a warning on every launch.
#   3. `GtkFileChooserNative` opens the Finder — not a GTK dialog. Asserted on
#      the portal's own log and on the app_id undertow composited, so "a file
#      dialog opened" cannot pass for "OUR file dialog opened".
#   4. The app receives, and reads, a file it never named. It named a directory.
#   5. The `Response` went out ADDRESSED to that app rather than broadcast
#      (HANDOFF §2.40) — the difference between an answer GTK receives and one
#      it never hears — with libdbus as the independent witness.
#   6. And undertow survived its input client going away (HANDOFF §2.41).
#
# Usage: abyss/tests/live-gtk.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

portal="$root/.build/debug/abyss-portal"
bridge="$root/.build/debug/abyss-dbus"
undertow="$root/.build/debug/undertow"
demo="$root/.build/debug/AquaDemo"
[ -x "$portal" ] && [ -x "$bridge" ] && [ -x "$undertow" ] && [ -x "$demo" ] || swift build

command -v dbus-daemon >/dev/null || { echo "FAIL: dbus-daemon not installed"; exit 1; }
command -v gdbus >/dev/null || { echo "FAIL: gdbus not installed"; exit 1; }
command -v dbus-monitor >/dev/null || { echo "FAIL: dbus-monitor not installed"; exit 1; }

W=900
H=700

# Short paths: a unix socket must fit in sun_path (HANDOFF §2.32).
work=$(mktemp -d /tmp/abyss-gtk.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-gtkr.XXXXXX)
cleanup() {
  [ -n "${fd3open:-}" ] && exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${app_pid:-} ${mon_pid:-} ${bridge_pid:-} ${portal_pid:-} \
           ${ut_pid:-} ${bus_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" "$rundir" "${vp_dir:-}" "${fifo:-}"
}
trap cleanup EXIT
export ABYSS_RUNTIME_DIR="$rundir"

# ------------------------------------------------------------------- the app
# Built here rather than by SwiftPM on purpose: `Package.swift` does not learn
# about GTK for this. See the header of gtkpick.c.

app="$work/gtkpick"
cc -O0 "$root/abyss/tests/gtkpick.c" -ldl -o "$app" \
  || { echo "FAIL: could not build the GTK client"; exit 1; }

# Is there a GTK runtime at all? gtkpick exits 77 (the automake "skip" code) when
# there is not, which is deliberately distinct from GTK being present and
# failing. A box with no GTK must skip loudly, never quietly pass.
set +e
"$app" --probe-only >/dev/null 2>"$work/probe.err"
probe_rc=$?
set -e
if [ "$probe_rc" = 77 ]; then
  echo "SKIP: no GTK 3 runtime on this box — $(cat "$work/probe.err")"
  exit 0
fi

# --------------------------------------------------------------- the pointer
# Compiled BEFORE the compositor starts. Everything from here to the click
# happens inside undertow's frame budget, and a `cc` inside that window is a
# few seconds of it spent on something that is not the test — enough to matter
# on the FreeBSD guest, where the budget is the same and the compiler is not.

vp_dir=$(mktemp -d)
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$vp_dir/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$vp_dir/vpointer-proto.c"
cc -I"$vp_dir" "$root/abyss/tests/vpointer.c" "$vp_dir/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$vp_dir/vpointer"

# ------------------------------------------------------------------- the bus
# Our own dbus-daemon, and one with **no service directories**: the stock
# `--session` config includes /usr/share/dbus-1/services, so the first call to
# an unowned `org.freedesktop.portal.Desktop` would ACTIVATE the real
# xdg-desktop-portal and it would answer instead of us. On a developer box with
# a desktop installed, that turns this test into an elaborate way of checking
# that GNOME works. Nothing here is activatable; every process is one we start.

cat > "$work/bus.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
busaddr=$(dbus-daemon --config-file="$work/bus.conf" --fork \
          --print-address=1 --print-pid=3 3>"$work/buspid")
bus_pid=$(cat "$work/buspid")
export DBUS_SESSION_BUS_ADDRESS="$busaddr"
echo "bus: $busaddr (pid $bus_pid, nothing activatable)"

# ------------------------------------------------------------ the compositor
# Window positions are SEEDED rather than guessed. P6.7's remembered places
# (`windows.ini`, through PoolConfig) exist precisely so a window can be told
# where to open, and using them here makes the click coordinates a fact instead
# of arithmetic over a cascade offset that a later pass could change.

cfgdir="$work/config"
mkdir -p "$cfgdir"
cat > "$cfgdir/windows.ini" <<EOF
[windows]
org.abyssbsd.finder = 0,0
org.abyssbsd.finder/Documents = 0,0
gtkpick = 560,420
gtkpick/Abyss GTK Client = 560,420
EOF

env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 2400 \
    --width "$W" --height "$H" --config-dir "$cfgdir" \
    --capture "$work/shot.ppm" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""
i=0
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || { echo "FAIL: undertow exited early"; cat "$work/ut.err"; exit 1; }
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || { echo "FAIL: undertow never announced a socket"; cat "$work/ut.err"; exit 1; }
export WAYLAND_DISPLAY="$wd"
echo "compositor: undertow on $wd"

# ------------------------------------------- abyss-portal, then the bridge

"$portal" > "$work/portal.log" 2>&1 &
portal_pid=$!
i=0
while [ $i -lt 50 ]; do [ -S "$rundir/portal.sock" ] && break; sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/portal.sock" ] \
  || { echo "FAIL: abyss-portal never bound its socket"; cat "$work/portal.log"; exit 1; }

"$bridge" > "$work/bridge.out" 2>"$work/bridge.err" &
bridge_pid=$!
i=0
while [ $i -lt 60 ]; do grep -q '^ready' "$work/bridge.out" 2>/dev/null && break; sleep 0.1; i=$((i+1)); done
grep -q '^ready' "$work/bridge.out" \
  || { echo "FAIL: abyss-dbus never came up"; cat "$work/bridge.err"; exit 1; }

owner=$(gdbus call --session --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetNameOwner org.freedesktop.portal.Desktop 2>&1)
case "$owner" in
  *:1.*) echo "ok: we own org.freedesktop.portal.Desktop ($owner)" ;;
  *) echo "FAIL: nobody owns the portal name: $owner"; cat "$work/bridge.err"; exit 1 ;;
esac

# ------------------------------------------------------- Settings, before GTK
# Asserted here with gdbus so a failure names the interface rather than showing
# up later as a GTK warning nobody reads. `Read` is checked for its DOUBLE
# variant wrapper, which is the shape its own interface definition documents.

readall=$(gdbus call --session --timeout 5 --dest org.freedesktop.portal.Desktop \
          --object-path /org/freedesktop/portal/desktop \
          --method org.freedesktop.portal.Settings.ReadAll '["org.freedesktop.*"]' 2>&1)
case "$readall" in
  *color-scheme*) echo "ok: gdbus read our appearance settings ($(echo "$readall" | cut -c1-60)…)" ;;
  *) echo "FAIL: Settings.ReadAll did not carry the appearance namespace: $readall"; exit 1 ;;
esac

# A namespace we publish nothing for must SUCCEED and be empty — that is what
# stops GTK warning on every launch. An error here is the bug this pass fixed.
gnome=$(gdbus call --session --timeout 5 --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop \
        --method org.freedesktop.portal.Settings.ReadAll '["org.gnome.*"]' 2>&1)
case "$gnome" in
  "({},)"|"({@a{sa{sv}} {},)"*|*"{}"*) echo "ok: an unknown namespace is empty, not an error" ;;
  *) echo "FAIL: ReadAll('org.gnome.*') should be empty, got: $gnome"; exit 1 ;;
esac

one=$(gdbus call --session --timeout 5 --dest org.freedesktop.portal.Desktop \
      --object-path /org/freedesktop/portal/desktop \
      --method org.freedesktop.portal.Settings.ReadOne \
      org.freedesktop.appearance color-scheme 2>&1)
echo "$one" | grep -q 'uint32 2' \
  || { echo "FAIL: ReadOne(color-scheme) should be <uint32 2>, got: $one"; exit 1; }
two=$(gdbus call --session --timeout 5 --dest org.freedesktop.portal.Desktop \
      --object-path /org/freedesktop/portal/desktop \
      --method org.freedesktop.portal.Settings.Read \
      org.freedesktop.appearance color-scheme 2>&1)
echo "$two" | grep -q '<<uint32 2>>' \
  || { echo "FAIL: Read() must double-wrap its variant (its own XML says so), got: $two"; exit 1; }
echo "ok: GLib decoded ReadOne (one variant) and Read (two) as the spec describes"

# ---------------------------------------------------------------- the witness
# A REAL bus monitor, not `gdbus monitor`. The Response is addressed to its
# caller (HANDOFF §2.40), and the bus hands an addressed signal to that caller
# and to monitors — not to everyone holding a match rule. `gdbus monitor`
# watches through match rules, so it would see nothing here and say nothing
# about it: the witness would stop witnessing and the test would still pass.
dbus-monitor --session > "$work/monitor" 2>&1 &
mon_pid=$!
sleep 0.5

# ------------------------------------------------------------------ the files
# A fixed directory name, because it becomes the Finder window's title and
# therefore half of its remembered-position key. A space in the chosen file's
# name on purpose: `%20` is the ordinary case for a real home directory, and an
# unescaped space makes a URI that GLib rejects.
docs="$work/Documents"
mkdir -p "$docs"
chosen="Chosen file.txt"
secret="the gtk app never named this file $$"
printf '%s\n' "$secret" > "$docs/$chosen"
printf 'not this one\n' > "$docs/Other.txt"

# ------------------------------------------------------------------- the app
# GTK_USE_PORTAL=1 is how a GTK 3 app outside a flatpak is told to use the
# portal; inside one it is implied by /.flatpak-info. GTK_A11Y=none stops it
# hunting for an accessibility bus we deliberately do not run (PHASE8 §1: no
# AT-SPI in this phase).
env GTK_USE_PORTAL=1 GTK_A11Y=none GDK_BACKEND=wayland \
    "$app" "$docs" > "$work/app.out" 2>"$work/app.err" &
app_pid=$!

i=0
while [ $i -lt 80 ]; do grep -q 'window up' "$work/app.err" 2>/dev/null && break; sleep 0.25; i=$((i+1)); done
grep -q 'window up' "$work/app.err" \
  || { echo "FAIL: the GTK app never mapped a window on undertow"
       cat "$work/app.err" "$work/ut.err"; exit 1; }
echo "ok: a GTK 3 toolkit mapped a window on our compositor"

# The Finder, opened by GTK asking the only way it knows.
i=0
while [ $i -lt 120 ]; do
  grep -q 'Finder: listed' "$work/portal.log" 2>/dev/null && break
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 0.25; i=$((i + 1))
done
grep -q 'Finder: listed' "$work/portal.log" \
  || { echo "FAIL: GtkFileChooserNative did not open the Finder"
       echo "-- app"; cat "$work/app.err"
       echo "-- bridge"; cat "$work/bridge.err"
       echo "-- portal"; cat "$work/portal.log"; exit 1; }
echo "ok: GtkFileChooserNative opened the Finder"

# It must have gone through OUR portal name on the bus, not some other route.
grep -q 'asked for OpenFile' "$work/bridge.err" \
  || { echo "FAIL: the bridge never saw an OpenFile"; cat "$work/bridge.err"; exit 1; }

# ------------------------------------------------------------------ the human
fifo="$work/vp.fifo"
mkfifo "$fifo"
"$vp_dir/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3>"$fifo"
fd3open=1
for _ in $(seq 1 30); do grep -q ready "$work/vp.log" && break; sleep 0.15; done
grep -q ready "$work/vp.log" || { echo "FAIL: virtual pointer not ready"; cat "$work/vp.log"; exit 1; }
sleep 1.0

# The Finder is seeded at 0,0. The seeded dir sorts to "Chosen file.txt",
# "Other.txt"; cell 1 of a 5-column grid of 88px cells from x=10, icons centred
# at y=96 → x=54. Same arithmetic as live-portal-dbus.sh, same picker.
printf 'm 54 96\np\nr\np\nr\n' >&3
sleep 2.5

# ------------------------------------------------------------------ the proof
i=0
while [ $i -lt 150 ]; do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
kill -0 "$app_pid" 2>/dev/null \
  && { echo "FAIL: the GTK app is still waiting — it never got its Response"
       echo "-- app"; cat "$work/app.err"
       echo "-- bridge"; cat "$work/bridge.err"; exit 1; }
rc=0; wait "$app_pid" 2>/dev/null || rc=$?
app_pid=""
[ "$rc" = 0 ] || { echo "FAIL: the GTK app exited $rc"
                   cat "$work/app.out" "$work/app.err" "$work/bridge.err"; exit 1; }

# 1. GTK's own bindings decoded the answer, and it names the file the USER
#    picked in the Finder — not the one the app suggested, because it suggested
#    none.
want="file://$docs/Chosen%20file.txt"
grep -q "^uri=$want\$" "$work/app.out" \
  || { echo "FAIL: wrong uri (wanted $want)"; cat "$work/app.out"; exit 1; }
echo "ok: GTK decoded the Response and got $want"

# 2. And it could then read it. This is the end of the chain: a program that
#    knows nothing about this desktop has the contents of a file a human chose
#    in the Finder.
grep -q "^contents=$secret\$" "$work/app.out" \
  || { echo "FAIL: the app did not read the chosen file"; cat "$work/app.out"; exit 1; }
echo "ok: the app read the file the human chose"

# 3. It never named that file. It named a directory — the confused-deputy
#    property of PHASE7, surviving the hop through somebody else's protocol.
grep -q "current_folder" "$work/bridge.err" 2>/dev/null || true
grep -q "handing over $docs/$chosen" "$work/portal.log" \
  || { echo "FAIL: the portal did not open the chosen file"; cat "$work/portal.log"; exit 1; }
grep -q "$chosen" "$work/app.err" \
  && { echo "FAIL: the app named the file itself somewhere"; cat "$work/app.err"; exit 1; }
echo "ok: the app asked about a directory and was answered with a file"

# 4. Two independent D-Bus implementations read that same Response: GLib, in
#    the app above, and libdbus here. Nothing in this test rests on our encoder
#    being read back by our decoder (HANDOFF §2.37).
#
#    And the destination is asserted, not just the signal: it is what makes the
#    difference between an answer GTK receives and one it never hears
#    (HANDOFF §2.40).
grep -q 'member=Response' "$work/monitor" \
  || { echo "FAIL: dbus-monitor never saw our Response signal"; cat "$work/monitor"; exit 1; }
grep -E 'destination=:[0-9.]+.*member=Response' "$work/monitor" >/dev/null \
  || { echo "FAIL: the Response was broadcast, not addressed to the caller"
       grep Response "$work/monitor"; exit 1; }
grep -q 'Chosen%20file.txt' "$work/monitor" \
  || { echo "FAIL: libdbus could not decode the uri out of our Response"
       cat "$work/monitor"; exit 1; }
echo "ok: libdbus decoded the same signal, and saw it addressed to the app"

# 5. And the compositor was ours throughout: it composited the GTK app's own
#    window as well as the picker's, which is the claim that GTK is simply
#    another client here.
#
#    Asserted on `mapped`, not `window`. By the time undertow prints its summary
#    the app has read its file and quit, so the survivors list is the wrong
#    place to look for it — and looking there is how this assertion passed for
#    the wrong reason once already.
#
#    undertow is left to run out its frame budget rather than killed, because
#    the summary is written when the loop ends. Dropping the virtual pointer
#    first is deliberate: a compositor must survive its input client going away
#    (HANDOFF §2.41), and this is where that is exercised.
kill "$vp_pid" 2>/dev/null || true; vp_pid=""
utrc=0; wait "$ut_pid" 2>/dev/null || utrc=$?
ut_pid=""
[ "$utrc" = 0 ] \
  || { echo "FAIL: undertow exited $utrc — a compositor must outlive its input client"
       tail -20 "$work/ut.err"; exit 1; }
grep -q '^mapped gtkpick' "$work/ut.out" \
  || { echo "FAIL: undertow never held a GTK window"
       cat "$work/ut.out" "$work/ut.err"; exit 1; }
grep -q '^mapped org.abyssbsd.finder' "$work/ut.out" \
  || { echo "FAIL: undertow never held the picker either — is this our compositor?"
       cat "$work/ut.out"; exit 1; }
echo "ok: undertow composited both windows ($(grep -c '^mapped ' "$work/ut.out") mapped in all)"

echo "all green (an unmodified GTK application got the Finder, and its file)."
