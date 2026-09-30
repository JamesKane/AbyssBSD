#!/bin/sh
# AbyssBSD Swift DE — dev session launcher (Phase 2.10).
#
# One command that brings the shell up as a *desktop* rather than as three
# separate AQUA_SCENE processes: it starts (or targets) a compositor, then runs
# the desktop, the menu bar and the Dock as clients against it and keeps them
# alive. This is the Linux stand-in for the sibling's `anchor` session
# supervisor — same job (own the session, start the components, restart one that
# dies, tear the whole thing down together), a fraction of the machinery.
#
# Usage:
#   abyss/session.sh [--nested|--attach|--headless] [options]
#
#     --nested        run a nested sway inside your current session (default
#                     when WAYLAND_DISPLAY is set) — the desktop appears in a
#                     window, which is the demo/dev loop.
#     --attach        run the components against the compositor already in
#                     WAYLAND_DISPLAY. Note this puts a menu bar and a Dock on
#                     *your* screen, over whatever else is running.
#     --headless      run a headless sway (pixman, no GPU). Nothing to see —
#                     for tests and --screenshot.
#     --resolution WxH   output size for --nested/--headless (default 1280x800).
#     --without NAME  drop a component (repeatable): desktop, menubar, dock.
#     --screenshot F  once every component has mapped, capture the session to F.
#     --once          exit as soon as everything has mapped (and been captured).
#     --rundir DIR    put logs/pids here (default: a temp dir, removed on exit).
#     --no-build      skip `swift build`.
#     --no-follow     don't tail the component logs to this terminal.
#
# Ctrl-C (or a `swaymsg exit` in the nested session) shuts the whole session
# down. Environment the components care about — ABYSS_CONFIG_DIR,
# ABYSS_DESKTOP_DIR, ABYSS_FINDER_DIR, AQUA_FONT — is inherited, so a caller can
# point a session at a scratch home without this script knowing about it.
set -eu

mode=""; res="1280x800"; screenshot=""; once=""; rundir=""; build=1; follow=1
components="desktop menubar dock"
max_restarts=5

drop() {  # remove one name from $components
  new=""
  for c in $components; do [ "$c" = "$1" ] || new="$new $c"; done
  components=$(printf '%s' "$new" | sed 's/^ //')
}

while [ $# -gt 0 ]; do
  case "$1" in
    --nested)     mode="nested" ;;
    --attach)     mode="attach" ;;
    --headless)   mode="headless" ;;
    --resolution) res="$2"; shift ;;
    --without)    drop "$2"; shift ;;
    --screenshot) screenshot="$2"; shift ;;
    --once)       once=1 ;;
    --rundir)     rundir="$2"; shift ;;
    --no-build)   build=0 ;;
    --no-follow)  follow=0 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *)            echo "session: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir      # FreeBSD sets none; sway refuses without it
bin="$root/.build/debug/AquaDemo"

# Default mode: nested if there's a compositor to nest inside, else headless.
if [ -z "$mode" ]; then
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then mode="nested"; else mode="headless"; fi
fi

[ "$build" = 1 ] && swift build
[ -x "$bin" ] || { echo "session: $bin not built"; exit 1; }
if [ "$mode" != "attach" ]; then
  command -v sway >/dev/null || { echo "session: sway not installed"; exit 1; }
fi
[ -n "$screenshot" ] && { command -v grim >/dev/null || { echo "session: grim not installed"; exit 1; }; }

if [ -n "$rundir" ]; then mkdir -p "$rundir"; keep_rundir=1
else rundir=$(mktemp -d); keep_rundir=0; fi

sway_pid=""; wd=""; stopping=""
cleanup() {
  [ -n "$stopping" ] && return 0
  stopping=1
  : > "$rundir/stopping"
  # Supervisors first (so none of them respawns), then the components they own.
  for c in $components; do
    s=$(cat "$rundir/$c.sup" 2>/dev/null) || s=""
    [ -n "$s" ] && kill "$s" 2>/dev/null || true
  done
  for c in $components; do
    p=$(cat "$rundir/$c.child" 2>/dev/null) || p=""
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
    t=$(cat "$rundir/$c.tail" 2>/dev/null) || t=""
    [ -n "$t" ] && kill "$t" 2>/dev/null || true
  done
  if [ -n "$sway_pid" ]; then
    [ -n "${SWAYSOCK:-}" ] && swaymsg exit >/dev/null 2>&1 || true
    kill "$sway_pid" 2>/dev/null || true
  fi
  [ "$keep_rundir" = 0 ] && rm -rf "$rundir" || true
}
trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------- compositor

if [ "$mode" = "attach" ]; then
  [ -n "${WAYLAND_DISPLAY:-}" ] || { echo "session: --attach needs WAYLAND_DISPLAY"; exit 1; }
  wd="$WAYLAND_DISPLAY"
  echo "session: attaching to the running compositor ($wd)"
else
  cfg="$rundir/sway.conf"
  {
    printf 'output * resolution %s position 0 0\n' "$res"
    printf 'default_border none\n'
    # A config file replaces sway's defaults, so without this there is no way
    # out of a nested session except killing this script.
    printf 'bindsym Mod4+Shift+q exit\n'
  } > "$cfg"
  if [ "$mode" = "nested" ]; then
    [ -n "${WAYLAND_DISPLAY:-}" ] || { echo "session: --nested needs a parent compositor"; exit 1; }
    # --unsupported-gpu is sway's proprietary-driver gate; it refuses to start
    # on an Nvidia box without it even though a nested session only draws into
    # the parent's surface. Nothing here depends on the GPU.
    WLR_BACKENDS=wayland sway --unsupported-gpu -c "$cfg" > "$rundir/sway.log" 2>&1 &
  else
    env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman \
        WLR_LIBINPUT_NO_DEVICES=1 sway --unsupported-gpu -c "$cfg" \
        > "$rundir/sway.log" 2>&1 &
  fi
  sway_pid=$!

  # Wait for the IPC socket, matched by *our* sway's pid — a stray sway (or a
  # concurrent live test) can't be picked up by mistake.
  ss=""
  for _ in $(seq 1 40); do
    ss=$(ls -1 "$XDG_RUNTIME_DIR"/sway-ipc.*."$sway_pid".sock 2>/dev/null | head -1) || ss=""
    [ -n "$ss" ] && SWAYSOCK="$ss" swaymsg -t get_version >/dev/null 2>&1 && break
    ss=""
    kill -0 "$sway_pid" 2>/dev/null || { echo "session: sway exited"; cat "$rundir/sway.log"; exit 1; }
    sleep 0.25
  done
  [ -n "$ss" ] || { echo "session: sway never came up"; tail "$rundir/sway.log"; exit 1; }
  export SWAYSOCK="$ss"

  # Then ask sway which Wayland socket it opened, rather than guessing from the
  # runtime dir: `swaymsg exec` runs the command in the session's environment,
  # so this is exact even with several compositors running side by side.
  # (Dump the whole environment and grep it here: sway lexes the exec string
  # itself, so quotes inside it don't survive to the shell.)
  swaymsg exec -- sh -c "env > $rundir/sway-env" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if [ -s "$rundir/sway-env" ]; then
      wd=$(grep '^WAYLAND_DISPLAY=' "$rundir/sway-env" | head -1 | cut -d= -f2-) || wd=""
      [ -n "$wd" ] && break
    fi
    sleep 0.1
  done
  if [ -z "$wd" ]; then
    # Fallback: the newest wayland-N socket that isn't the parent session's.
    wd=$(ls -1t "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' \
         | grep -v "^${WAYLAND_DISPLAY:-wayland-0}\$" | head -1) || true
    [ -n "$wd" ] || { echo "session: cannot tell which Wayland socket sway opened"; exit 1; }
  fi
  echo "session: $mode sway ready on $wd ($res)"
fi

printf '%s\n' "$wd" > "$rundir/wayland-display"
[ -n "${SWAYSOCK:-}" ] && printf '%s\n' "$SWAYSOCK" > "$rundir/swaysock"
[ -n "$sway_pid" ] && printf '%s\n' "$sway_pid" > "$rundir/sway.pid"
echo "session: rundir=$rundir"

# ---------------------------------------------------------------- components

scene_of() {
  case "$1" in
    desktop) echo wallpaper ;;   # the wallpaper scene *is* the desktop (icons and all)
    menubar) echo menubar ;;
    dock)    echo dock ;;
    *)       echo "session: unknown component '$1'" >&2; exit 2 ;;
  esac
}

# Start one component under a restart supervisor. A component that dies comes
# back (that is the whole point of a session supervisor), but one that dies
# *immediately*, over and over, is a broken build — give up rather than spin.
supervise() {
  name=$1; scene=$2; log="$rundir/$name.log"
  : > "$log"
  (
    fails=0
    while :; do
      started=$(date +%s)
      # ABYSS_APP_BINARY is what the Dock re-runs to launch an app; pin it to
      # the binary we started rather than leaving it to /proc/self/exe.
      env WAYLAND_DISPLAY="$wd" AQUA_SCENE="$scene" ABYSS_APP_BINARY="$bin" \
          "$bin" >> "$log" 2>&1 &
      child=$!
      printf '%s\n' "$child" > "$rundir/$name.child"
      wait "$child" || true
      if [ -e "$rundir/stopping" ]; then exit 0; fi
      ran=$(( $(date +%s) - started ))
      if [ "$ran" -ge 5 ]; then fails=0; fi
      fails=$((fails + 1))
      if [ "$fails" -gt "$max_restarts" ]; then
        printf 'session: %s failed %d times in a row — giving up\n' "$name" "$fails" >&2
        exit 1
      fi
      printf 'session: %s exited after %ds — restarting (%d/%d)\n' \
             "$name" "$ran" "$fails" "$max_restarts" >&2
      sleep 1
    done
  ) &
  printf '%s\n' "$!" > "$rundir/$name.sup"
  # Mirror the component's log to this terminal, tagged. awk (not sed) because
  # fflush() keeps it line-live in a pipe on both GNU and BSD.
  if [ "$follow" = 1 ]; then
    tail -n +1 -F "$log" 2>/dev/null | awk -v n="$name" '{print "[" n "] " $0; fflush()}' &
    printf '%s\n' "$!" > "$rundir/$name.tail"
  fi
}

for c in $components; do
  supervise "$c" "$(scene_of "$c")"
done

# Every component is a wlr-layer-shell client, and a layer surface is not in
# sway's tree (no app_id, not a toplevel) — so "it came up" is the component's
# own mapped log line, exactly as the live tests assert it.
for c in $components; do
  up=0
  for _ in $(seq 1 40); do
    if grep -q 'LayerSurface: mapped' "$rundir/$c.log" 2>/dev/null; then up=1; break; fi
    sleep 0.25
  done
  if [ "$up" != 1 ]; then
    echo "session: $c never mapped" >&2; cat "$rundir/$c.log" >&2; exit 1
  fi
done
echo "session: up — $(printf '%s' "$components" | tr '\n' ' ')"

if [ -n "$screenshot" ]; then
  sleep 1   # let a couple of frames paint before the capture
  WAYLAND_DISPLAY="$wd" grim "$screenshot"
  test -s "$screenshot" || { echo "session: grim produced no image" >&2; exit 1; }
  echo "session: captured $screenshot"
fi

[ -n "$once" ] && exit 0

if [ -n "$sway_pid" ]; then
  echo "session: running — Ctrl-C here, or Mod4+Shift+Q in the session, to quit."
  wait "$sway_pid" || true       # quitting the compositor ends the session
else
  echo "session: running — Ctrl-C to quit."
  while :; do sleep 3600; done
fi
