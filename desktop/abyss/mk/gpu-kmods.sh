#!/bin/sh
# The medium's GPU kernel modules, built from the monorepo's forks against the
# distribution sets' own kernel sources: drm-kmod (kmod/drm: dmabuf, ttm, drm,
# amdgpu, radeonkms, i915kms) and the AMD firmware (firmware/) for the GPUs
# live-image.sh has always carried. Prints the directory of .ko files, for
# `live-image.sh --kmods`.
#
# **Why not packages.** Every module records the __FreeBSD_version it was
# built for, and a kernel refuses one newer than itself. The sets are pinned
# (config.sh's checksums), the package repository is not: on 2026-10-31 it
# served drm-612-kmod and the firmware built for 1600029 to a medium whose
# kernel is 1600026, and amdgpu did not load ("depends on kernel - not
# available or version mismatch"). Built here, against SYSDIR, they match
# the sets by construction — and they are our forks, which is what the
# medium should carry anyway.
#
# SYSDIR defaults to /usr/src/sys, which fetch-sets.sh unpacks from the same
# snapshot as the sets. Objects go under OBJ (not the synced trees, which
# sync.sh --delete would empty); the result is reused while no source is
# newer than it and SYSDIR's version has not changed.
#
#   usage: abyss/mk/gpu-kmods.sh [OUT]       (default ~/gpu-kmods)
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
mono=$(cd "$root/.." && pwd)
out=${1:-/home/$(id -un)/gpu-kmods}
sysdir=${SYSDIR:-/usr/src/sys}
obj=${OBJ:-/home/$(id -un)/gpu-obj}
drm="$mono/kmod/drm"
fw="$mono/firmware"
# The GPUs the medium carries firmware for: the RX 6000 series (navy_flounder
# is the 12700KF box's RX 6750 XT) and Southern Islands (the 2013 Mac Pro's
# FirePros) — live-image.sh's GPU_PKGS list, by the firmware's own names.
AMD_FIRMWARE="navy_flounder sienna_cichlid dimgrey_cavefish beige_goby
              tahiti pitcairn verde oland hainan"

die() { echo "gpu-kmods: $*" >&2; exit 1; }
[ "$(uname -s)" = FreeBSD ] || die "kernel modules build on FreeBSD"
[ -f "$sysdir/sys/param.h" ] || die "no kernel sources at $sysdir (abyss/vm/fetch-sets.sh unpacks them)"
[ -f "$drm/Makefile" ] || die "no drm-kmod fork at $drm"
[ -f "$fw/Makefile" ] || die "no firmware fork at $fw"
version=$(awk '/^#define[[:blank:]]__FreeBSD_version/ {print $3}' "$sysdir/sys/param.h")

stamp="$out/.built-for"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$version $sysdir" ] \
   && [ -z "$(find "$drm" "$fw" -newer "$stamp" -type f -print 2>/dev/null | head -1)" ]; then
  echo "$out"
  exit 0
fi

jobs=$(sysctl -n hw.ncpu)
build() {  # build DIR MAKE-ARGS...: objects under $obj, never in the tree
  d=$1; shift
  env MAKEOBJDIRPREFIX="$obj" make -C "$d" SYSDIR="$sysdir" "$@" obj > /dev/null
  env MAKEOBJDIRPREFIX="$obj" make -C "$d" -j"$jobs" SYSDIR="$sysdir" DEBUG_FLAGS= "$@" \
    || die "the build in $d failed"
}
log="$obj.log"
mkdir -p "$obj"
{
  build "$drm"
  # shellcheck disable=SC2086
  build "$fw" KMODS=amdgpukmsfw AMDGPUKMODS="$(echo $AMD_FIRMWARE)"
} > "$log" 2>&1 || { tail -20 "$log" >&2; die "see $log"; }

rm -rf "$out"; mkdir -p "$out"
find "$obj" -name '*.ko' -exec install -m 555 {} "$out/" \;
n=$(find "$out" -name '*.ko' | wc -l | tr -d ' ')
[ -f "$out/amdgpu.ko" ] || die "no amdgpu.ko came out of $drm"
[ "$n" -gt 20 ] || die "only $n modules came out"
echo "$version $sysdir" > "$stamp"
echo "$out"
