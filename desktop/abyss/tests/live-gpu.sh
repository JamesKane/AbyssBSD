#!/bin/sh
# AbyssBSD Swift DE — a GPU client, on our own compositor (U.3).
#
# undertow offered wl_shm and nothing else, and Mesa's Wayland WSI hands the
# compositor dma-bufs: with no `linux-dmabuf`, vkcube on RADV segfaulted and
# es2gears fell back to drawing in software (docs/API-STUDY.md §1.2). Every
# harness run renders with pixman, which imports no dma-bufs, so nothing here
# could see it; the metal box's RX 6750 XT would have.
#
# Two halves:
#
#   always    pixman undertow says, in words, that it does not offer
#             linux-dmabuf — a machine with no GPU (the build VM) is told why
#             GPU clients fail, instead of finding out from a crash;
#   GPU       undertow on a real render node — an AMD one if there is one, the
#             RX 6750 XT's driver family — offers it, and a GL client
#             (es2gears) and a Vulkan client (vkcube) each run, open THAT node,
#             and are seen animating through screencopy.
#
# The GPU half skips, loudly, without a render node or without the two
# clients (mesa-demos' es2gears_wayland, vulkan-tools' vkcube).
#
# Also the witness for the screenshot fix that fell out of U.3. Each GPU
# renderer offers screencopy its own pixel format — on the dev box, AMD's
# GLES2 offers XB24 and NVIDIA's offers 24-bit BG24, which abyssgrab could not
# read — so every render node here gets one screencopy, checked to the exact
# desktop colour, which only a right channel order and byte width produce.
#
# Usage: abyss/tests/live-gpu.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
grab="$root/.build/debug/abyssgrab"
[ -x "$undertow" ] && [ -x "$grab" ] || swift build

W=800
H=600
work=$(mktemp -d /tmp/abyss-gpu.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${cl_pid:-} ${vk_pid:-} ${vp_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

start_undertow() {  # start_undertow LOGNAME [ENV...]
  name=$1; shift
  env -u WAYLAND_DISPLAY "$@" "$undertow" run --frames 0 --width "$W" --height "$H" \
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
grep -q 'undertow: linux-dmabuf not offered' "$work/pixman.err" \
  || fail "pixman undertow did not say it offers no linux-dmabuf: $(grep dmabuf "$work/pixman.err")"
kill "$ut_pid"; wait "$ut_pid" 2>/dev/null || true; ut_pid=""
echo "ok: with pixman, undertow says linux-dmabuf is not offered, and why"

# ------------------------------------------------------------- the render node
node=""
for d in /sys/class/drm/renderD*; do
  [ -e "$d" ] || continue
  n="/dev/dri/${d##*/}"
  [ -z "$node" ] && node=$n                       # any, if there is no AMD
  if [ "$(cat "$d/device/vendor" 2>/dev/null)" = 0x1002 ]; then node=$n; break; fi
done
if [ -z "$node" ]; then
  echo "SKIP: no GPU render node here, so no GPU client can be run (the build VM has none)"
  echo "all green (pixman half only)."
  exit 0
fi
for c in es2gears_wayland vkcube; do
  command -v "$c" >/dev/null 2>&1 \
    || { echo "SKIP: $c is not installed (mesa-demos / vulkan-tools)"; echo "all green (pixman half only)."; exit 0; }
done
vendor=$(cat "/sys/class/drm/${node##*/}/device/vendor" 2>/dev/null || echo "?")
echo "ok: GPU half on $node (vendor $vendor)"

hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')

# ------------------------------------------------- screencopy, every renderer
# The desktop undertow paints is Jaguar blue, 61 102 161: a swapped channel
# order or a wrong byte width cannot produce it by accident.
for d in /sys/class/drm/renderD*; do
  [ -e "$d" ] || continue
  n="/dev/dri/${d##*/}"
  start_undertow "shot-${d##*/}" WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE="$n"
  env WAYLAND_DISPLAY="$wd" "$grab" "$work/shot.ppm" > "$work/shot.log" 2>&1 \
    || fail "screencopy failed on the GPU renderer on $n ($(cat "$d/device/vendor")): $(cat "$work/shot.log")"
  px=$(dd if="$work/shot.ppm" bs=1 skip=$((hdr_len + (((20 * W) + 20) * 3))) count=3 2>/dev/null \
       | od -An -tu1 | awk '{ print $1, $2, $3 }')
  [ "$px" = "61 102 161" ] \
    || fail "screencopy on $n ($(cat "$d/device/vendor")) reads the desktop as $px, not 61 102 161"
  kill "$ut_pid"; wait "$ut_pid" 2>/dev/null || true; ut_pid=""
  echo "ok: a screenshot on the GPU renderer on $n ($(cat "$d/device/vendor")) is the right colour"
done

# ------------------------------------------------------------- GPU: undertow
start_undertow gles2 WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE="$node"
grep -q 'undertow: linux-dmabuf offered' "$work/gles2.err" \
  || fail "on $node, undertow did not offer linux-dmabuf: $(grep -i 'dmabuf\|render' "$work/gles2.err")"
echo "ok: on a GPU renderer, undertow offers linux-dmabuf"

# es2gears destroys a pointer and keyboard it never made when the seat has
# neither — its bug, not ours, and a headless seat is the only one with
# neither — so the seat gets both first, as any real desktop's has.
for x in wlr-virtual-pointer-unstable-v1:vpointer virtual-keyboard-unstable-v1:vkeyboard; do
  xml=${x%%:*}; n=${x##*:}
  wayland-scanner client-header "$root/abyss/tests/$xml.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$xml.xml" "$work/$n-proto.c"
  cc -I"$work" "$root/abyss/tests/$n.c" "$work/$n-proto.c" \
     $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/$n" \
     || fail "could not build $n"
done
mkfifo "$work/p" "$work/k"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" "$W" "$H" < "$work/p" > /dev/null 2>&1 &
vp_pid=$!
exec 3> "$work/p"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$work/k" > /dev/null 2>&1 &
exec 4> "$work/k"
sleep 0.8
printf 'm %s %s\n' "$((W - 5))" "$((H - 5))" >&3    # the cursor, off every window

# Every 10th pixel of a window's box, one "R G B" per line.
samples() {  # samples PPM X Y WIDTH HEIGHT
  f=$1; x0=$2; y0=$3; bw=$4; bh=$5; r=5
  while [ "$r" -lt "$bh" ]; do
    dd if="$f" bs=1 skip=$((hdr_len + ((((y0 + r) * W) + x0) * 3))) count=$((bw * 3)) \
       2>/dev/null | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
       | awk '{ v[NR % 3] = $1 } NR % 3 == 0 && (NR / 3) % 10 == 5 { print v[1], v[2], v[0] }'
    r=$((r + 10))
  done
}

# The client runs, opens the node undertow renders on, and is seen moving.
gpu_client() {  # gpu_client NAME KEY-SUFFIX COMMAND...
  name=$1; suffix=$2; shift 2
  env WAYLAND_DISPLAY="$wd" "$@" > "$work/$name.log" 2>&1 &
  cl_pid=$!
  box=""; i=0
  while [ $i -lt 50 ]; do
    box=$(grep "^window [^ ]*$suffix " "$work/gles2.out" 2>/dev/null | tail -1 | cut -d' ' -f3,4) || box=""
    [ -n "$box" ] && break
    kill -0 "$cl_pid" 2>/dev/null || fail "$name exited before it mapped a window: $(tail -3 "$work/$name.log")"
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$box" ] || fail "$name never mapped a window"
  sleep 1.5
  kill -0 "$cl_pid" 2>/dev/null || fail "$name died after mapping: $(tail -3 "$work/$name.log")"
  # Which GPU it is really on: the kernel's word, not the client's.
  if [ -d "/proc/$cl_pid/fd" ]; then
    ls -l "/proc/$cl_pid/fd" 2>/dev/null | grep -q " -> $node\$" \
      || fail "$name is running, but not on $node: $(ls -l "/proc/$cl_pid/fd" | grep -o '/dev/dri/[a-zA-Z0-9]*' | sort -u | tr '\n' ' ')"
    echo "ok: $name is running on $node"
  fi
  bx=${box%%,*}; rest=${box#*,}; by=${rest%% *}; size=${box#* }; bw=${size%x*}; bh=${size#*x}
  env WAYLAND_DISPLAY="$wd" "$grab" "$work/$name-1.ppm" > /dev/null 2>&1 \
    || fail "screencopy failed on a GPU renderer — the 24-bit BG24 format? $(env WAYLAND_DISPLAY="$wd" "$grab" "$work/x.ppm" 2>&1)"
  sleep 0.5
  env WAYLAND_DISPLAY="$wd" "$grab" "$work/$name-2.ppm" > /dev/null 2>&1 || fail "the second screencopy failed"
  samples "$work/$name-1.ppm" "$bx" "$by" "$bw" "$bh" > "$work/$name-1.txt"
  samples "$work/$name-2.ppm" "$bx" "$by" "$bw" "$bh" > "$work/$name-2.txt"
  colours=$(sort -u "$work/$name-1.txt" | wc -l | tr -d ' ')
  [ "$colours" -ge 4 ] || fail "$name's window shows $colours colour(s) — it is not drawing (a blank or unimported buffer)"
  cmp -s "$work/$name-1.txt" "$work/$name-2.txt" \
    && fail "$name's window is identical half a second apart — its frames are not arriving"
  echo "ok: $name is seen through screencopy — $colours colours, and moving"
  kill "$cl_pid"; wait "$cl_pid" 2>/dev/null || true; cl_pid=""
  sleep 0.3
}

gpu_client es2gears es2gears/es2gears es2gears_wayland

# vkcube picks a discrete GPU by default, which need not be the node above,
# and Vulkan's device numbering is not stable: Mesa's device-select layer
# reorders it by the compositor it is talking to (index 1 was the AMD iGPU
# under vulkaninfo and the NVIDIA card under this undertow). So name the
# device, and let Mesa expose only that one.
device=$(cat "/sys/class/drm/${node##*/}/device/device" 2>/dev/null || echo "")
[ -n "$device" ] || fail "no PCI device id for $node"
gpu_client vkcube /vkcube env MESA_VK_DEVICE_SELECT="${vendor#0x}:${device#0x}" \
    MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1 vkcube --wsi wayland

kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited: $(tail -5 "$work/gles2.err")"
echo "all green (a GL and a Vulkan client present through linux-dmabuf on our own compositor)."
