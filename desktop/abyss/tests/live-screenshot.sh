#!/bin/sh
# AbyssBSD Swift DE — the screenshot portal (PHASE7.md P7.5).
#
# The file chooser's claim was "the app reads a file it could not have opened".
# This one is sharper, because the capability isn't a file the user already had:
#
#   A process in Capsicum capability mode cannot call socket(2), so it cannot
#   connect to the compositor, so it cannot capture anything. It has no
#   filesystem, so it cannot read a capture someone else made. It nonetheless
#   ends up holding a PNG of the screen — and the portal gave it no path,
#   because there is no longer a path: the image was unlinked before the
#   descriptor was sent.
#
# Four real processes: a headless sway showing an actual Jaguar desktop
# (wallpaper + menu bar + Dock), abyss-portal, the abyssgrab helper it forks,
# and abyssopen as the sandboxed client.
#
# Usage: abyss/tests/live-screenshot.sh [out.png]
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

out=${1:-}
portal="$root/.build/debug/abyss-portal"
client="$root/.build/debug/abyssopen"
grabber="$root/.build/debug/abyssgrab"
bin="$root/.build/debug/AquaDemo"
[ -x "$portal" ] && [ -x "$client" ] && [ -x "$grabber" ] && [ -x "$bin" ] || swift build
command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }

# The output we capture, so the assertion on the PNG's size is an exact one.
W=520
H=400

rundir=$(mktemp -d /tmp/abyss-shot.XXXXXX)
deskdir=$(mktemp -d /tmp/abyss-shotdesk.XXXXXX)

cleanup() {
  for p in ${app_pids:-} ${portal_pid:-} ${sway_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$rundir" "$deskdir" "${cfg:-}" "${swaylog:-}"
}
trap cleanup EXIT
export ABYSS_RUNTIME_DIR="$rundir"

# ---------------------------------------------------------------- compositor

cfg=$(mktemp)
printf 'output HEADLESS-1 resolution %sx%s position 0 0\ndefault_border none\n' "$W" "$H" > "$cfg"
swaylog=$(mktemp)
env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman \
    WLR_LIBINPUT_NO_DEVICES=1 sway --unsupported-gpu -c "$cfg" > "$swaylog" 2>&1 &
sway_pid=$!

# Match OUR sway by pid and ask it which socket it opened, rather than guessing
# at the runtime dir — the developer's own session is in there (HANDOFF §2.26).
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

# ---------------------------------------------------------------- a desktop
# Put something on the screen worth capturing. An empty compositor would give a
# perfectly valid screenshot of nothing, and a "is it a PNG of the right size?"
# check would pass on it — the failure this test most has to be able to see.

app_pids=""
for scene in wallpaper menubar dock; do
  env -u AQUA_SCALE ABYSS_DESKTOP_DIR="$deskdir" ABYSS_FINDER_DIR="$deskdir" \
      AQUA_SCENE="$scene" "$bin" >/dev/null 2>"$rundir/$scene.log" &
  app_pids="$app_pids $!"
done
mapped=0
i=0
while [ $i -lt 60 ]; do
  n=$(grep -l 'LayerSurface: mapped' "$rundir"/wallpaper.log "$rundir"/menubar.log \
        "$rundir"/dock.log 2>/dev/null | wc -l)
  [ "$n" -ge 3 ] && { mapped=1; break; }
  sleep 0.25; i=$((i + 1))
done
[ "$mapped" = 1 ] || { echo "FAIL: the desktop never mapped"
                       tail -3 "$rundir"/*.log; exit 1; }
sleep 0.8      # let the first frames land before we photograph them
echo "desktop: wallpaper + menu bar + Dock are on screen"

# ---------------------------------------------------------------- the portal

# No --grabber: let the portal resolve `abyssgrab` beside its own executable,
# which is what it does in a real session. live-portal.sh leaves --picker off
# for the same reason.
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
# stdout is the PNG; stderr is the narration.

rc=0
"$client" --screenshot > "$rundir/shot.png" 2> "$rundir/client.log" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL: the client exited $rc"
                   cat "$rundir/client.log" "$rundir/portal.log"; exit 1; }

# ---------------------------------------------------------------- the proof

# 1. What crossed the socket is a real PNG, of this output — checked by the
#    client itself, from the bytes it read through the descriptor.
grep -q "verified: a real PNG, ${W}x${H}," "$rundir/client.log" \
  || { echo "FAIL: the client did not read a valid ${W}x${H} PNG"
       cat "$rundir/client.log" "$rundir/portal.log"; exit 1; }
echo "ok: the bytes it read through the descriptor are a ${W}x${H} PNG"

# 2. ...and it is a picture of something. A blank buffer encodes to a few
#    hundred bytes; the Jaguar desktop above does not. This is the assertion
#    that a size check alone would miss (HANDOFF §2.34: probe the thing, not
#    something near it).
bytes=$(wc -c < "$rundir/shot.png" | tr -d ' ')
[ "$bytes" -gt 5000 ] \
  || { echo "FAIL: the screenshot is $bytes bytes — that is a blank screen, not a desktop"
       exit 1; }
echo "ok: it is a picture of the desktop, not an empty buffer ($bytes bytes)"

# 3. The portal named it nothing, and left nothing named. The image was
#    unlinked before the descriptor was sent, so the runtime dir is clean and
#    the reply carried no path for anyone — sandboxed or not — to reopen.
grep -q "and no path for it (path in reply: none)" "$rundir/client.log" \
  || { echo "FAIL: the reply carried a path for the screenshot"
       cat "$rundir/client.log"; exit 1; }
leftover=$(ls -1 "$rundir"/shot.*.png 2>/dev/null | head -1) || leftover=""
[ -z "$leftover" ] \
  || { echo "FAIL: the portal left $leftover behind for anyone to read"; exit 1; }
echo "ok: no path in the reply, and no file left in the runtime dir"

# 4. The client could not have taken this picture itself. Capturing a screen
#    means connecting to the compositor, and capability mode forbids naming an
#    address — connect(2) on a path — even though it permits socket(2) itself.
if [ "$(uname -s)" = "FreeBSD" ]; then
  grep -q "capability mode entered" "$rundir/client.log" \
    || { echo "FAIL: the client never entered capability mode"
         cat "$rundir/client.log"; exit 1; }
  grep -q "control: connect(2) to .* failed" "$rundir/client.log" \
    || { echo "FAIL: connect(2) did NOT fail inside the sandbox — the sandbox isn't real"
         cat "$rundir/client.log"; exit 1; }
  echo "ok: connect(2) to the compositor FAILED inside capability mode"
  grep "control: connect(2)" "$rundir/client.log" | sed 's/^/    /'
  echo "all green (a picture of the screen, held by a process that cannot reach the screen)."
else
  # The honest fallback, as live-sandbox.sh does: say plainly that the
  # confinement isn't there rather than let a reader assume it.
  grep -q "sandbox: NOT AVAILABLE" "$rundir/client.log" \
    || { echo "FAIL: on $(uname -s) the client must report that it is unsandboxed"
         cat "$rundir/client.log"; exit 1; }
  echo "ok: on $(uname -s) it reports plainly that it is NOT sandboxed"
  # And here the control earns its keep: unsandboxed, the very same call
  # SUCCEEDS against the very same compositor. That is what makes the FreeBSD
  # failure evidence of the sandbox rather than of a missing socket.
  grep -q "control: connect(2) to .* succeeded" "$rundir/client.log" \
    || { echo "FAIL: unsandboxed, connect(2) to the compositor should have succeeded"
         echo "      — the control proves nothing if it fails everywhere"
         cat "$rundir/client.log"; exit 1; }
  echo "ok: ...and unsandboxed, that same connect(2) succeeds — the control is real"
  echo "all green (the capability claim itself is proved on FreeBSD only)."
fi

[ -n "$out" ] && cp "$rundir/shot.png" "$out" && echo "wrote $out"
exit 0
