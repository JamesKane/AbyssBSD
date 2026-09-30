#!/bin/sh
# Build wtap.ko with station and access-point modes for THIS FreeBSD
# (PHASE14 P14.5): 15.0's own wtap, plus upstream d4de0a69a92
# (wtap-sta-hostap.patch) and our teardown fixes (wtap-teardown.patch), as an
# out-of-tree module against /usr/src/sys.
#
# 15.0-RELEASE's wtap does mesh and ad-hoc only, so a station could not join
# an access point in the harness; upstream added both, with WPA, after 15.0.
# FreeBSD main (16-CURRENT) has that commit already, so the patch is applied
# only to a source without it — and our teardown fixes, which main does not
# have, go on either way. /usr/src/sys comes from the guest's src.txz
# (abyss/vm/fetch-sets.sh).
#
# Usage: build-wtap.sh OUTDIR   -> OUTDIR/wtap.ko and OUTDIR/wtapctl
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build-wtap.sh OUTDIR}
[ "$(uname -s)" = FreeBSD ] || { echo "build-wtap.sh: wtap is FreeBSD's" >&2; exit 2; }
[ -f /usr/src/sys/dev/wtap/if_wtap.c ] || { echo "build-wtap.sh: no /usr/src/sys (fetch the release's src.txz)" >&2; exit 2; }
mkdir -p "$out"
b=$(mktemp -d /tmp/abyss-wtap.XXXXXX)
trap 'rm -rf "$b"' EXIT
cp -R /usr/src/sys/dev/wtap "$b/src"
# Ask the source whether it can already be an access point, rather than
# whether the patch reverses: main has moved on around those lines since
# d4de0a69a92 (more capabilities on the same line), so neither direction of
# the patch matches it.
if grep -q 'IEEE80211_C_HOSTAP' "$b/src/if_wtap.c"; then
  base="this FreeBSD's wtap, which has station and access-point modes"
else
  ( cd "$b/src" && sed -n '/^diff/,$p' "$here/wtap-sta-hostap.patch" | patch -s -p4 ) \
    || { echo "build-wtap.sh: the patch does not apply to this if_wtap.c" >&2; exit 1; }
  base="this FreeBSD's wtap + d4de0a69a92"
fi
# And ours: three teardown bugs, each a kernel panic (wtap-teardown.patch).
( cd "$b/src" && patch -s -p1 < "$here/wtap-teardown.patch" ) \
  || { echo "build-wtap.sh: wtap-teardown.patch does not apply" >&2; exit 1; }
cp /usr/src/sys/modules/wtap/Makefile "$b/Makefile"
# The module Makefile names its sources relative to SRCTOP/sys/dev/wtap; point
# it at the patched copy instead.
sed -i '' "s|^\.PATH:.*|.PATH: $b/src $b/src/wtap_hal $b/src/plugins|" "$b/Makefile"
( cd "$b" && make -s SYSDIR=/usr/src/sys DEBUG_FLAGS=-g >"$b/build.log" 2>&1 ) \
  || { tail -20 "$b/build.log" >&2; echo "build-wtap.sh: the module did not build" >&2; exit 1; }
cp "$b/wtap.ko" "$out/wtap.ko"
[ -f "$b/wtap.ko.debug" ] && cp "$b/wtap.ko.debug" "$out/wtap.ko.debug"      # for kgdb on a crash
cc -o "$out/wtapctl" "$here/wtapctl.c"
echo "built $out/wtap.ko ($base, + teardown fixes) and $out/wtapctl"
