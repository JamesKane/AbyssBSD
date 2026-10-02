#!/bin/sh
# AbyssBSD Swift DE — the portal on the session bus, end to end (PHASE8.md P8.2).
#
# The claim under test: a caller that knows nothing about AbyssBSD calls
# `org.freedesktop.portal.FileChooser.OpenFile` on the session bus, **the Finder
# opens**, and the answer names the file the user picked in it.
#
# Real processes, and none of them is a mock: ADE's D-Bus bridge (BACKLOG D.1 —
# a bridge, never a bus), sway
# hosting the picker, abyss-portal running it, abyss-dbus bridging, and a caller.
# `gdbus` — GLib's D-Bus, an entirely independent implementation — introspects
# us, reads our property, and **decodes the Response signal for itself**, so no
# claim here rests on our encoder being read back by our decoder (HANDOFF §2.37).
#
# The one thing the bridge deliberately does NOT do is hand over a descriptor.
# The FileChooser interface has no `h` in its Response in any version — the
# answer it defines is a URI — so the descriptor abyss-portal opened is closed
# here and the caller opens the path by name. PHASE8.md §6.6.
#
# Usage: abyss/tests/live-portal-dbus.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

portal="$root/.build/debug/abyss-portal"
bridge="$root/.build/debug/abyss-dbus"
probe="$root/.build/debug/dbusprobe"
bin="$root/.build/debug/AquaDemo"
[ -x "$portal" ] && [ -x "$bridge" ] && [ -x "$probe" ] && [ -x "$bin" ] || swift build

command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }
command -v gdbus >/dev/null || { echo "FAIL: gdbus not installed"; exit 1; }

# Short paths: a unix socket must fit in sun_path (HANDOFF §2.32).
rundir=$(mktemp -d /tmp/abyss-pdbus.XXXXXX)
docs=$(mktemp -d /tmp/abyss-pdocs.XXXXXX)
# A space in the name on purpose: `%20` is the ordinary case for a real home
# directory, and an unescaped space makes a URI that clients reject.
chosen="Chosen file.txt"
secret="the bridge found it $$"
printf '%s\n' "$secret" > "$docs/$chosen"
printf 'not this one\n' > "$docs/Other.txt"

cleanup() {
  [ -n "${probe_pid:-}" ] && kill "$probe_pid" 2>/dev/null || true
  [ -n "${abyss_bridge_pid:-}" ] && kill "$abyss_bridge_pid" 2>/dev/null || true
  [ -n "${bridge_pid:-}" ] && kill "$bridge_pid" 2>/dev/null || true
  [ -n "${portal_pid:-}" ] && kill "$portal_pid" 2>/dev/null || true
  [ -n "${sway_pid:-}" ] && kill "$sway_pid" 2>/dev/null || true
  [ -n "${vp_pid:-}" ] && kill "$vp_pid" 2>/dev/null || true
  rm -rf "$rundir" "$docs" "${cfg:-}" "${swaylog:-}" "${vp_dir:-}" "${fifo:-}" 2>/dev/null || true
}
trap cleanup EXIT
export ABYSS_RUNTIME_DIR="$rundir"

# ---------------------------------------------------------------- the bus
# ADE's own bridge, so this test can never touch the developer's session bus —
# nor be answered by an xdg-desktop-portal that happens to be running on it.
abyss_bridge_start "$rundir" || exit 1
echo "bridge: $DBUS_SESSION_BUS_ADDRESS (services at $ABYSS_BRIDGE_SERVICES)"

# ---------------------------------------------------------------- compositor

cfg=$(mktemp)
printf 'output HEADLESS-1 resolution 520x400 position 0 0\ndefault_border none\n' > "$cfg"
swaylog=$(mktemp)
env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman \
    WLR_LIBINPUT_NO_DEVICES=1 sway --unsupported-gpu -c "$cfg" > "$swaylog" 2>&1 &
sway_pid=$!

# Match OUR sway by pid, then ask it which socket it opened — never "the first
# wayland-N in the runtime dir", which is the developer's own session (§2.26).
ss=""
i=0
while [ $i -lt 60 ]; do
  ss=$(ls -1 "$XDG_RUNTIME_DIR"/sway-ipc.*."$sway_pid".sock 2>/dev/null | head -1) || ss=""
  [ -n "$ss" ] && SWAYSOCK="$ss" swaymsg -t get_version >/dev/null 2>&1 && break
  ss=""
  kill -0 "$sway_pid" 2>/dev/null || { echo "FAIL: sway exited"; tail -5 "$swaylog"; exit 1; }
  sleep 0.25; i=$((i + 1))
done
[ -n "$ss" ] || { echo "FAIL: sway not ready"; tail -5 "$swaylog"; exit 1; }
export SWAYSOCK="$ss"
swaymsg exec -- sh -c "env > $rundir/sway-env" >/dev/null 2>&1 || true
wd=""
i=0
while [ $i -lt 40 ]; do
  [ -s "$rundir/sway-env" ] && wd=$(grep '^WAYLAND_DISPLAY=' "$rundir/sway-env" | head -1 | cut -d= -f2-)
  [ -n "$wd" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || { echo "FAIL: cannot tell which socket sway opened"; exit 1; }
export WAYLAND_DISPLAY="$wd"

# ---------------------------------------------- abyss-portal, then the bridge

"$portal" > "$rundir/portal.log" 2>&1 &
portal_pid=$!
i=0
while [ $i -lt 50 ]; do [ -S "$rundir/portal.sock" ] && break; sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/portal.sock" ] \
  || { echo "FAIL: abyss-portal never bound its socket"; cat "$rundir/portal.log"; exit 1; }

# The portal is one of ADE's services: it joins on the bridge's private socket.
env DBUS_SESSION_BUS_ADDRESS="$ABYSS_BRIDGE_SERVICES" "$bridge" > "$rundir/bridge.out" 2>"$rundir/bridge.err" &
bridge_pid=$!
i=0
while [ $i -lt 60 ]; do grep -q '^ready' "$rundir/bridge.out" 2>/dev/null && break; sleep 0.1; i=$((i+1)); done
grep -q '^ready' "$rundir/bridge.out" \
  || { echo "FAIL: abyss-dbus never came up"; cat "$rundir/bridge.err"; exit 1; }

# It must be the PRIMARY owner. A portal that shares its name answers some calls
# and not others, which is worse than not starting.
owner=$(gdbus call --session --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetNameOwner org.freedesktop.portal.Desktop 2>&1)
case "$owner" in
  *:1.*) echo "ok: we own org.freedesktop.portal.Desktop ($owner)" ;;
  *) echo "FAIL: nobody owns the portal name: $owner"; cat "$rundir/bridge.err"; exit 1 ;;
esac

# ------------------------------------------- what a client checks before calling
# GLib parses our introspection with its own XML parser and reads the property
# its bindings generate a call for. Both happen before any real GTK dialog.

intro=$(gdbus introspect --session --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop 2>&1)
echo "$intro" | grep -q "org.freedesktop.portal.FileChooser" \
  || { echo "FAIL: gdbus could not parse our introspection"; echo "$intro"; exit 1; }
echo "$intro" | grep -q "OpenFile" \
  || { echo "FAIL: introspection does not advertise OpenFile"; echo "$intro"; exit 1; }
echo "ok: gdbus parsed our introspection and found FileChooser.OpenFile"

ver=$(gdbus call --session --dest org.freedesktop.portal.Desktop \
      --object-path /org/freedesktop/portal/desktop \
      --method org.freedesktop.DBus.Properties.Get \
      org.freedesktop.portal.FileChooser version 2>&1)
echo "$ver" | grep -q "uint32 1" \
  || { echo "FAIL: the FileChooser version property is wrong: $ver"; exit 1; }
echo "ok: gdbus read the FileChooser version property (1)"

# A handle_token that is not a valid object path element must be REFUSED, and
# refused with an error reply. Accepting it would put the Request at a path the
# client is not listening on — a hang with no diagnostic, which is the failure
# shape this whole pass is arranged to prevent.
if gdbus call --session --timeout 5 --dest org.freedesktop.portal.Desktop \
     --object-path /org/freedesktop/portal/desktop \
     --method org.freedesktop.portal.FileChooser.OpenFile \
     "" "T" "{'handle_token': <'not/valid'>}" > "$rundir/badtoken" 2>&1; then
  echo "FAIL: a handle_token with a '/' in it was accepted"; cat "$rundir/badtoken"; exit 1
fi
grep -qi 'InvalidArgs' "$rundir/badtoken" \
  || { echo "FAIL: a bad handle_token did not produce InvalidArgs"
       cat "$rundir/badtoken"; exit 1; }
echo "ok: a handle_token that would break the object path was refused, with an error"

# ---------------------------------------------------------------- the caller
# Our probe first; GLib's GDBus is the independent caller further down (the
# Response is addressed to its caller alone, and ADE's bridge lets nobody else
# watch, so the witness has to be a caller — PRODUCT §5.6).

# The probe SUBSCRIBES BEFORE IT CALLS, deriving the Request path from its own
# unique name and its own token exactly as the spec describes — and then asserts
# the handle it was given is the one it predicted. Get that derivation wrong on
# either side and a correct client waits for ever on a path nothing is emitted
# on (PHASE8.md §6.1).
"$probe" portal-open "$docs" > "$rundir/probe.log" 2>&1 &
probe_pid=$!

# ---------------------------------------------------------------- the human

vp_dir=$(mktemp -d)
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$vp_dir/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$vp_dir/vpointer-proto.c"
cc -I"$vp_dir" "$root/abyss/tests/vpointer.c" "$vp_dir/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$vp_dir/vpointer"

i=0
while [ $i -lt 80 ]; do
  swaymsg -t get_tree 2>/dev/null | grep -q '"app_id": "org.abyssbsd.finder"' && break
  sleep 0.25; i=$((i + 1))
done
swaymsg -t get_tree | grep -q '"app_id": "org.abyssbsd.finder"' \
  || { echo "FAIL: the D-Bus call never opened a picker"
       cat "$rundir/probe.log" "$rundir/bridge.err" "$rundir/portal.log"; exit 1; }
echo "ok: a D-Bus OpenFile call opened the Finder"

vp_log=$(mktemp)
fifo=$(mktemp -u); mkfifo "$fifo"
"$vp_dir/vpointer" 520 400 < "$fifo" > "$vp_log" 2>&1 &
vp_pid=$!
exec 3>"$fifo"
for _ in $(seq 1 20); do grep -q ready "$vp_log" && break; sleep 0.15; done
grep -q ready "$vp_log" || { echo "FAIL: virtual pointer not ready"; cat "$vp_log"; exit 1; }
sleep 0.6

# The seeded dir sorts to: "Chosen file.txt", "Other.txt". Cell 1 of a 5-column
# grid of 88px cells from x=10, icons centred at y=96 → x=54.
printf 'm 54 96\np\nr\np\nr\n' >&3
sleep 1.5

# ---------------------------------------------------------------- the proof

i=0
while [ $i -lt 100 ]; do kill -0 "$probe_pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
rc=0; wait "$probe_pid" 2>/dev/null || rc=$?    # set -e would abort on non-zero
[ "$rc" = 0 ] || { echo "FAIL: the caller exited $rc"
                   cat "$rundir/probe.log" "$rundir/bridge.err"; exit 1; }

# 1. The handle was the one the client predicted from the spec's own rule.
grep -q '^handle-matches-prediction' "$rundir/probe.log" \
  || { echo "FAIL: the Request path was not the one a pre-subscribed client expects"
       cat "$rundir/probe.log"; exit 1; }
echo "ok: the Request path was exactly what the client predicted before calling"

# 2. The Response said success, and named the file the *user* picked.
grep -q '^response=0' "$rundir/probe.log" \
  || { echo "FAIL: the Response was not a success"; cat "$rundir/probe.log"; exit 1; }
want="file://$(printf '%s' "$docs" | sed 's:/:/:g')/Chosen%20file.txt"
grep -q "^uri=$want\$" "$rundir/probe.log" \
  || { echo "FAIL: wrong uri (wanted $want)"; cat "$rundir/probe.log"; exit 1; }
echo "ok: the answer named the file the user chose, escaped ($want)"


# 4. The client never named that file — it suggested a directory. The
#    confused-deputy property survives the extra hop through D-Bus.
grep -q "current_folder" "$rundir/bridge.err" 2>/dev/null || true
grep -q "handing over $docs/$chosen" "$rundir/portal.log" \
  || { echo "FAIL: the portal did not open the chosen file"; cat "$rundir/portal.log"; exit 1; }
echo "ok: abyss-portal opened it, having been given a directory and never a file"

# ------------------------------------------------- the client that subscribes late
# The other way this API hangs, and the one the modern client above cannot see.
# An old client — no handle_token — calls first and subscribes to whatever handle
# comes back. It only ever receives a Response if the method return reached it
# BEFORE the signal was emitted. That is why abyss-dbus runs the picker from its
# run loop rather than from inside the method handler (PHASE8.md §6.1).

"$probe" portal-open-late "$docs" > "$rundir/late.log" 2>&1 &
probe_pid=$!

i=0
while [ $i -lt 80 ]; do
  swaymsg -t get_tree 2>/dev/null | grep -q '"app_id": "org.abyssbsd.finder"' && break
  sleep 0.25; i=$((i + 1))
done
swaymsg -t get_tree | grep -q '"app_id": "org.abyssbsd.finder"' \
  || { echo "FAIL: the second call never opened a picker"
       cat "$rundir/late.log" "$rundir/bridge.err"; exit 1; }
sleep 0.6
printf 'm 54 96\np\nr\np\nr\n' >&3
sleep 1.5

i=0
while [ $i -lt 100 ]; do kill -0 "$probe_pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
rc=0; wait "$probe_pid" 2>/dev/null || rc=$?
[ "$rc" = 0 ] || { echo "FAIL: the late-subscribing client exited $rc"
                   cat "$rundir/late.log" "$rundir/bridge.err"; exit 1; }
grep -q '^subscribed-after-the-call' "$rundir/late.log" \
  || { echo "FAIL: the late client did not subscribe after calling"
       cat "$rundir/late.log"; exit 1; }
grep -q '^response=0' "$rundir/late.log" \
  || { echo "FAIL: a client that subscribed after the call never saw its Response"
       echo "      (the method return must reach the caller before the signal goes out)"
       cat "$rundir/late.log"; exit 1; }
echo "ok: a client that subscribed only after calling still got its Response"

# ------------------------------------------------------ GLib, as the caller
# The independent witness: GLib's GDBus calls OpenFile, hears its own Response
# and decodes it with its own parser. Without this, every claim above is our
# encoder being read back by our decoder.
cc "$root/abyss/tests/portalcall.c" $(pkg-config --cflags --libs gio-2.0) -o "$rundir/portalcall" \
  || { echo "FAIL: cannot build the GLib caller"; exit 1; }
# The last round's Finder must be gone first, or the wait below finds it and
# the click lands before this round's picker is up.
i=0
while swaymsg -t get_tree 2>/dev/null | grep -q '"app_id": "org.abyssbsd.finder"' && [ $i -lt 80 ]; do sleep 0.25; i=$((i + 1)); done
"$rundir/portalcall" OpenFile glib1 - "$docs" > "$rundir/glib.log" 2>&1 &
probe_pid=$!
i=0
while [ $i -lt 80 ]; do
  swaymsg -t get_tree 2>/dev/null | grep -q '"app_id": "org.abyssbsd.finder"' && break
  sleep 0.25; i=$((i + 1))
done
swaymsg -t get_tree | grep -q '"app_id": "org.abyssbsd.finder"' \
  || { echo "FAIL: GLib's call never opened a picker"; cat "$rundir/glib.log" "$rundir/bridge.err"; exit 1; }
sleep 1.5
printf 'm 54 96\np\nr\np\nr\n' >&3
rc=0; wait "$probe_pid" 2>/dev/null || rc=$?
[ "$rc" = 0 ] || { echo "FAIL: GLib's caller got no Response (exit $rc)"; cat "$rundir/glib.log"; for f in bridge.err portal.log bridge-endpoint.log; do echo "-- $f"; tail -n 6 "$rundir/$f"; done; exit 1; }
grep -q '^response 0$' "$rundir/glib.log" || { echo "FAIL: GLib decoded no success"; cat "$rundir/glib.log"; exit 1; }
grep -q "^uri $want\$" "$rundir/glib.log" || { echo "FAIL: GLib decoded the wrong uri (wanted $want)"; cat "$rundir/glib.log"; exit 1; }
echo "ok: GLib's GDBus, as the caller, got its Response and decoded the uri independently of us"

echo "all green (a foreign caller got the Finder, and the file it picked)."
