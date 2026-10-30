#!/bin/sh
# Build the FreeBSD/riscv64 sysroot the cross-build links against (RUST.md
# R0, §6.9), from the builder VM: the poudriere `rv64` jail's world (our
# src/ fork, built for riscv64) and the packages poudriere built in it.
# The repository is kept beside it too, so the rv64 guest can install the
# same packages with pkg (rv64-guest-pkgs.sh).
#
#   abyss/vm/rv64-sysroot.sh       # the builder must be running
#
# Outputs, outside the monorepo:
#   $ABYSS_RV64_SYSROOT   base (lib, usr/lib, usr/include, usr/libdata, libexec)
#                         + every package unpacked under usr/local
#   $ABYSS_RV64_PKGS      the package repository, as poudriere left it
set -eu
ABYSS_VM_ROLE=builder
. "$(dirname "$0")/config.sh"

jail=/usr/local/poudriere/jails/rv64
repo=/usr/local/poudriere/data/packages/rv64-default/.latest
# shellcheck disable=SC2046
bssh() { ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$@" </dev/null; }

bssh "test -d $jail && test -d $repo/All" \
  || { echo "rv64-sysroot: no rv64 jail or packages on the builder (RUST.md R0)" >&2; exit 1; }

rm -rf "$ABYSS_RV64_SYSROOT" "$ABYSS_RV64_PKGS"
mkdir -p "$ABYSS_RV64_SYSROOT" "$ABYSS_RV64_PKGS"

echo "[sysroot] base from the builder's rv64 jail"
# GNU tar warns about FreeBSD's file flags (SCHILY.fflags); they don't matter here.
bssh "cd $jail && tar -cf - lib usr/lib usr/include usr/libdata libexec" \
  | tar -xf - -C "$ABYSS_RV64_SYSROOT" 2>&1 | grep -v SCHILY || true

echo "[sysroot] the package repository"
bssh "cd $repo && tar -cf - All Latest data.pkg meta meta.conf packagesite.pkg" \
  | tar -xf - -C "$ABYSS_RV64_PKGS"

echo "[sysroot] unpacking packages"
n=0
for p in "$ABYSS_RV64_PKGS"/All/*.pkg; do
  # A package is a zstd tar of absolute paths plus +MANIFEST metadata.
  tar --zstd -xf "$p" -C "$ABYSS_RV64_SYSROOT" --exclude='+*'
  n=$((n + 1))
done
echo "[sysroot] $n packages; done: $ABYSS_RV64_SYSROOT"
