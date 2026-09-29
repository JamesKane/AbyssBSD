#!/bin/sh
# AbyssBSD Swift DE — the capability claim, proved (PHASE7.md P7.3).
#
# live-portal.sh shows a client receiving a descriptor. This shows the claim that
# makes the design worth having: the client has **no filesystem at all** — it is
# in Capsicum capability mode — and still reads the file the user picked.
#
# The negative is what makes the positive mean anything, so it is asserted too:
# open(2) on that same path must FAIL from inside the sandbox. Without that,
# "it read the file" proves only that files can be read.
#
# Capsicum is FreeBSD-only. On Linux this asserts the honest fallback instead:
# the client must SAY it is unsandboxed rather than imply a confinement it
# doesn't have.
#
# Usage: abyss/tests/live-sandbox.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

portal="$root/.build/debug/abyss-portal"
client="$root/.build/debug/abyssopen"
[ -x "$portal" ] && [ -x "$client" ] || swift build
command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }

rundir=$(mktemp -d /tmp/abyss-sbx.XXXXXX)
docs=$(mktemp -d /tmp/abyss-sbxdocs.XXXXXX)
secret="no filesystem, and yet $$"
printf '%s\n' "$secret" > "$docs/Secret.txt"

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

# ---------------------------------------------------------------- portal

"$portal" --once > "$rundir/portal.log" 2>&1 &
portal_pid=$!
i=0
while [ $i -lt 50 ]; do
  [ -S "$rundir/portal.sock" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -S "$rundir/portal.sock" ] \
  || { echo "FAIL: the portal never bound"; cat "$rundir/portal.log"; exit 1; }

# ---------------------------------------------------------------- the client
# stdout is the file's contents; stderr is the narration.

"$client" "$docs" > "$rundir/out.txt" 2> "$rundir/client.log" &
client_pid=$!

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
  || { echo "FAIL: no picker appeared"; cat "$rundir/portal.log" "$rundir/client.log"; exit 1; }

vp_log=$(mktemp)
fifo=$(mktemp -u); mkfifo "$fifo"
"$vp_dir/vpointer" 520 400 < "$fifo" > "$vp_log" 2>&1 &
vp_pid=$!
exec 3>"$fifo"
for _ in $(seq 1 20); do grep -q ready "$vp_log" && break; sleep 0.15; done
grep -q ready "$vp_log" || { echo "FAIL: virtual pointer not ready"; cat "$vp_log"; exit 1; }
sleep 0.6
printf 'm 54 96\np\nr\np\nr\n' >&3      # the only file in the folder
sleep 1.5

# ---------------------------------------------------------------- the proof

i=0
while [ $i -lt 60 ]; do
  kill -0 "$client_pid" 2>/dev/null || break
  sleep 0.1; i=$((i + 1))
done
rc=0; wait "$client_pid" 2>/dev/null || rc=$?    # set -e would abort on non-zero
[ "$rc" = 0 ] \
  || { echo "FAIL: the client exited $rc"; cat "$rundir/client.log"; exit 1; }

# It read the file — through the descriptor, since that is all it has.
grep -q "$secret" "$rundir/out.txt" \
  || { echo "FAIL: the client didn't read the file"
       cat "$rundir/out.txt" "$rundir/client.log"; exit 1; }
echo "ok: the client read the chosen file"

if [ "$(uname -s)" = "FreeBSD" ]; then
  grep -q "capability mode entered" "$rundir/client.log" \
    || { echo "FAIL: the client never entered capability mode"
         cat "$rundir/client.log"; exit 1; }
  echo "ok: it was in Capsicum capability mode when it did"

  # THE POINT: the same path is unreachable by name from in there.
  grep -q "control: open(2) on that path failed" "$rundir/client.log" \
    || { echo "FAIL: open(2) did NOT fail inside the sandbox — the sandbox isn't real"
         cat "$rundir/client.log"; exit 1; }
  echo "ok: open(2) on that same path FAILED — it could not have opened the file itself"
  grep "control: open(2)" "$rundir/client.log" | sed 's/^/    /'
  echo "all green (the descriptor is the capability, and nothing else is)."
else
  # The honest fallback: no Capsicum here, and the client must say so rather
  # than let a reader assume it was confined.
  grep -q "sandbox: NOT AVAILABLE" "$rundir/client.log" \
    || { echo "FAIL: on $(uname -s) the client must report that it is unsandboxed"
         cat "$rundir/client.log"; exit 1; }
  echo "ok: on $(uname -s) it reports plainly that it is NOT sandboxed"
  echo "all green (the capability claim itself is proved on FreeBSD only)."
fi
