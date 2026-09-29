#!/bin/sh
# AbyssBSD Swift DE — explicit sync, on our own compositor (BACKLOG U.3b).
#
# linux-drm-syncobj-v1: a GPU client's buffer comes with an acquire point
# (don't read it before this) and a release point (signal this when done with
# it — the client will draw into it again). undertow's scene waits on the one
# and arms the other, as wlr_scene does; it is offered only where the renderer
# and the backend take timelines. Mesa's Vulkan WSI uses it whenever it is
# offered, so vkcube is the client:
#
#   always    pixman undertow says, in words, that it does not offer
#             linux-drm-syncobj, and why (the build VM, every software run);
#   GPU       on every render node undertow offers it; vkcube binds it and gives
#             every commit an acquire and a release point; and it keeps
#             presenting — a compositor that never signalled a release would
#             stall it within its swapchain's few images — while undertow
#             arms each release and draws each texture behind its wait.
#
# The GPU half skips, loudly, without a render node or vkcube.
#
# Usage: abyss/tests/live-syncobj.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build

work=$(mktemp -d /tmp/abyss-syncobj.XXXXXX)
cleanup() {
  for p in ${cl_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; grep -E '^explicit-sync' "$work"/*.out 2>/dev/null | tail -2 | sed 's/^/  undertow| /'; exit 1; }

start_undertow() {  # start_undertow LOGNAME [ENV...]
  name=$1; shift
  env -u WAYLAND_DISPLAY "$@" "$undertow" run --frames 0 --width 800 --height 600 \
      --config-dir "$work" > "$work/$name.out" 2> "$work/$name.err" &
  ut_pid=$!
  wd=""; i=0
  while [ $i -lt 80 ]; do
    wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/$name.out" 2>/dev/null | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && return 0
    kill -0 "$ut_pid" 2>/dev/null || { cat "$work/$name.err"; fail "undertow ($name) exited before it announced a socket"; }
    sleep 0.1; i=$((i + 1))
  done
  fail "undertow ($name) never announced a socket"
}

# ------------------------------------------------------------- always: pixman
start_undertow pixman
grep -q 'undertow: linux-drm-syncobj not offered — this renderer takes no timeline waits' "$work/pixman.err" \
  || fail "pixman undertow did not say it offers no linux-drm-syncobj, and why: $(grep -i syncobj "$work/pixman.err")"
kill "$ut_pid"; wait "$ut_pid" 2>/dev/null || true; ut_pid=""
echo "ok: with pixman, undertow says linux-drm-syncobj is not offered, and why"

# ------------------------------------------------------------- every render node
# Each GPU on the box in turn — on the dev box an AMD iGPU (radv: implicit
# sync would do) and an NVIDIA card (its driver is why explicit sync exists).
nodes=""
for d in /sys/class/drm/renderD*; do [ -e "$d" ] && nodes="$nodes /dev/dri/${d##*/}"; done
if [ -z "$nodes" ]; then
  echo "SKIP: no GPU render node here (the build VM has none)"
  echo "all green (pixman half only)."
  exit 0
fi
command -v vkcube >/dev/null 2>&1 || { echo "SKIP: vkcube is not installed (vulkan-tools)"; echo "all green (pixman half only)."; exit 0; }

for node in $nodes; do
  vendor=$(cat "/sys/class/drm/${node##*/}/device/vendor"); device=$(cat "/sys/class/drm/${node##*/}/device/device")
  tag="$node ($vendor)"
  start_undertow "gles2-${node##*/}" WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE="$node"
  out="$work/gles2-${node##*/}"
  grep -q 'undertow: linux-drm-syncobj offered' "$out.err" \
    || fail "on $tag, undertow did not offer linux-drm-syncobj: $(grep -i 'syncobj' "$out.err")"
  # The device named, as live-gpu.sh does: Vulkan's numbering is not stable.
  env WAYLAND_DISPLAY="$wd" WAYLAND_DEBUG=client MESA_VK_DEVICE_SELECT="${vendor#0x}:${device#0x}" \
      MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1 vkcube --wsi wayland > "$work/vk.out" 2> "$work/vk.err" &
  cl_pid=$!
  sleep 4
  kill -0 "$cl_pid" 2>/dev/null || fail "on $tag vkcube exited: $(grep -v '^\[' "$work/vk.err" | tail -3)"
  # Which GPU it is really on: the kernel's word, not the client's.
  on="(unchecked)"
  if [ -d "/proc/$cl_pid/fd" ]; then
    ls -l "/proc/$cl_pid/fd" 2>/dev/null | grep -q " -> $node\$" \
      || fail "vkcube is running, but not on $node: $(ls -l "/proc/$cl_pid/fd" | grep -o '/dev/dri/[a-zA-Z0-9]*' | sort -u | tr '\n' ' ')"
    on="vkcube on it"
  fi
  kill "$cl_pid"; wait "$cl_pid" 2>/dev/null || true; cl_pid=""
  grep -q 'bind(.*"wp_linux_drm_syncobj_manager_v1"' "$work/vk.err" || fail "on $tag vkcube did not bind wp_linux_drm_syncobj_manager_v1"
  acq=$(grep -c 'wp_linux_drm_syncobj_surface_v1#[0-9]*\.set_acquire_point' "$work/vk.err" || true)
  rel=$(grep -c 'wp_linux_drm_syncobj_surface_v1#[0-9]*\.set_release_point' "$work/vk.err" || true)
  [ "$acq" -ge 100 ] && [ "$rel" -ge 100 ] \
    || fail "on $tag, in 4 s vkcube set $acq acquire and $rel release points — it stalled (a release never signalled?) or never used explicit sync"
  # undertow's side, after its warm-up report (§2.83).
  i=0; while ! grep -q '^explicit-sync ' "$out.out" && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
  line=$(grep '^explicit-sync ' "$out.out" | tail -1)
  armed=$(printf '%s' "$line" | sed -n 's/.*releases-armed=\([0-9]*\).*/\1/p')
  waits=$(printf '%s' "$line" | sed -n 's/.*acquire-waits=\([0-9]*\).*/\1/p')
  [ "${armed:-0}" -ge 100 ] || fail "on $tag undertow armed ${armed:-0} release points, not one per vkcube buffer"
  [ "${waits:-0}" -ge 100 ] || fail "on $tag undertow drew ${waits:-0} textures behind an acquire wait"
  kill -0 "$ut_pid" 2>/dev/null || fail "undertow on $tag exited: $(tail -5 "$out.err")"
  kill "$ut_pid"; wait "$ut_pid" 2>/dev/null || true; ut_pid=""
  echo "ok: $tag, $on: offered; vkcube gave $acq commits an acquire and $rel a release point in 4 s without stalling; undertow armed $armed releases and drew $waits textures behind their waits"
done

echo "all green (explicit sync: offered where it can be kept, and kept — through undertow)."
