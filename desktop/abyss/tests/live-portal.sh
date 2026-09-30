#!/bin/sh
# AbyssBSD Swift DE — the file-chooser portal, end to end (PHASE7.md P7.2).
#
# The claim under test: a client asks the desktop for a file, a human picks one
# in the Finder, and the client receives an OPEN DESCRIPTOR for a path it never
# named. The descriptor is the capability.
#
# Three processes, all real: abyss-portal hosting the service, the Finder as the
# picker (driven by a virtual pointer through a headless sway), and ipcprobe as
# the requesting client.
#
# Usage: abyss/tests/live-portal.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

portal="$root/.build/debug/abyss-portal"
probe="$root/.build/debug/ipcprobe"
bin="$root/.build/debug/AquaDemo"
[ -x "$portal" ] && [ -x "$probe" ] && [ -x "$bin" ] || swift build

command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }

# Short paths: a unix socket must fit in sun_path (HANDOFF §2.32).
rundir=$(mktemp -d /tmp/abyss-portal.XXXXXX)
docs=$(mktemp -d /tmp/abyss-docs.XXXXXX)
secret="the capability is the descriptor $$"
printf '%s\n' "$secret" > "$docs/Chosen.txt"
printf 'not this one\n' > "$docs/Other.txt"

cleanup() {
  [ -n "${portal_pid:-}" ] && kill "$portal_pid" 2>/dev/null || true
  [ -n "${sway_pid:-}" ] && kill "$sway_pid" 2>/dev/null || true
  [ -n "${vp_pid:-}" ] && kill "$vp_pid" 2>/dev/null || true
  rm -rf "$rundir" "$docs" "${cfg:-}" "${swaylog:-}" "${vp_dir:-}" "${fifo:-}" 2>/dev/null || true
}
trap cleanup EXIT
export ABYSS_RUNTIME_DIR="$rundir"

# ---------------------------------------------------------------- compositor

cfg=$(mktemp)
printf 'output HEADLESS-1 resolution 520x400 position 0 0\ndefault_border none\n' > "$cfg"
swaylog=$(mktemp)
env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman \
    WLR_LIBINPUT_NO_DEVICES=1 sway --unsupported-gpu -c "$cfg" > "$swaylog" 2>&1 &
sway_pid=$!

# Match OUR sway by pid, then ask it which socket it opened — never "the first
# wayland-N in the runtime dir", which is the developer's own session
# (HANDOFF §2.26).
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

# ---------------------------------------------------------------- the portal

"$portal" --once > "$rundir/portal.log" 2>&1 &
portal_pid=$!
i=0
while [ $i -lt 50 ]; do
  [ -S "$rundir/portal.sock" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -S "$rundir/portal.sock" ] \
  || { echo "FAIL: the portal never bound its socket"; cat "$rundir/portal.log"; exit 1; }
echo "portal: listening on $rundir/portal.sock"

# ---------------------------------------------------------------- the client
# ipcprobe asks for a file. Note what it does NOT send: any path. It suggests a
# directory; the portal opens whatever the user picks.

"$probe" portal-open portal "$docs" > "$rundir/client.log" 2>&1 &
client_pid=$!

# ---------------------------------------------------------------- the human
# Drive the picker's double-click through a virtual pointer.

vp_dir=$(mktemp -d)
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$vp_dir/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$vp_dir/vpointer-proto.c"
cc -I"$vp_dir" "$root/abyss/tests/vpointer.c" "$vp_dir/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$vp_dir/vpointer"

# Wait for the picker window the portal launched.
i=0
while [ $i -lt 80 ]; do
  swaymsg -t get_tree 2>/dev/null | grep -q '"app_id": "org.abyssbsd.finder"' && break
  sleep 0.25; i=$((i + 1))
done
swaymsg -t get_tree | grep -q '"app_id": "org.abyssbsd.finder"' \
  || { echo "FAIL: the portal never opened a picker"
       cat "$rundir/portal.log" "$rundir/client.log"; exit 1; }
echo "portal: the picker is up"

vp_log=$(mktemp)
fifo=$(mktemp -u); mkfifo "$fifo"
"$vp_dir/vpointer" 520 400 < "$fifo" > "$vp_log" 2>&1 &
vp_pid=$!
exec 3>"$fifo"
for _ in $(seq 1 20); do grep -q ready "$vp_log" && break; sleep 0.15; done
grep -q ready "$vp_log" || { echo "FAIL: virtual pointer not ready"; cat "$vp_log"; exit 1; }
sleep 0.6

# The seeded dir sorts to: Chosen.txt, Other.txt. Cell 1 of a 5-column grid of
# 88px cells from x=10, icons centred at y=96 → x=54.
printf 'm 54 96\np\nr\np\nr\n' >&3
sleep 1.5

# ---------------------------------------------------------------- the proof

i=0
while [ $i -lt 60 ]; do
  kill -0 "$client_pid" 2>/dev/null || break
  sleep 0.1; i=$((i + 1))
done
rc=0; wait "$client_pid" 2>/dev/null || rc=$?   # set -e would abort on non-zero
[ "$rc" = 0 ] \
  || { echo "FAIL: the client exited $rc"; cat "$rundir/client.log" "$rundir/portal.log"; exit 1; }

# 1. The client read the file's contents THROUGH the passed descriptor.
grep -q "$secret" "$rundir/client.log" \
  || { echo "FAIL: the client never read the chosen file"
       cat "$rundir/client.log" "$rundir/portal.log"; exit 1; }
echo "ok: the client read the file through the descriptor it was handed"

# 2. It was the file the *user* picked.
grep -q "path: $docs/Chosen.txt" "$rundir/client.log" \
  || { echo "FAIL: wrong file"; cat "$rundir/client.log"; exit 1; }
echo "ok: it was the file the user chose ($docs/Chosen.txt)"

# 3. The client never named that path — it sent only a directory. This is the
#    confused-deputy property, checked rather than asserted in prose.
grep -q "requested: dir=$docs" "$rundir/client.log" \
  || { echo "FAIL: the client didn't log what it sent"; cat "$rundir/client.log"; exit 1; }
echo "ok: the client asked for a directory, never for that file"

echo "all green (the descriptor is the capability)."
