#!/bin/sh
# Cross-build for FreeBSD/riscv64 from the host (RUST.md §6.9): run a
# command with the environment cargo, the cc crate and pkg-config need to
# target the sysroot rv64-sysroot.sh made.
#
#   abyss/vm/rv64-cross.sh cargo +$ABYSS_RUST_NIGHTLY build --release \
#       -Zbuild-std=std,panic_abort --target riscv64gc-unknown-freebsd
#
# riscv64gc-unknown-freebsd is Tier 3: no prebuilt std, hence the pinned
# nightly and -Zbuild-std. The compiler is the host's own clang and lld,
# never Swift's toolchain (it leaves with Swift, R7).
set -eu
. "$(dirname "$0")/config.sh"

[ -d "$ABYSS_RV64_SYSROOT/usr/local/lib" ] \
  || { echo "rv64-cross: no sysroot; run abyss/vm/rv64-sysroot.sh" >&2; exit 1; }

# One wrapper serves as C compiler and linker. It is regenerated each run,
# since it carries the sysroot's path.
cc="$ABYSS_VM_HOME/rv64-clang"
sr="$ABYSS_RV64_SYSROOT"
cat > "$cc" <<EOF
#!/bin/sh
exec $ABYSS_RV64_HOST_CLANG --target=riscv64-unknown-freebsd16.0 --sysroot=$sr -fuse-ld=lld \\
  -Qunused-arguments -L$sr/usr/local/lib \\
  -Wl,-rpath-link,$sr/usr/local/lib -Wl,-rpath-link,$sr/lib -Wl,-rpath-link,$sr/usr/lib "\$@"
EOF
chmod +x "$cc"

export CC_riscv64gc_unknown_freebsd="$cc"
export AR_riscv64gc_unknown_freebsd="$ABYSS_RV64_HOST_AR"
export CARGO_TARGET_RISCV64GC_UNKNOWN_FREEBSD_LINKER="$cc"
export PKG_CONFIG_SYSROOT_DIR="$sr"
export PKG_CONFIG_LIBDIR="$sr/usr/local/libdata/pkgconfig:$sr/usr/local/share/pkgconfig:$sr/usr/libdata/pkgconfig"
export PKG_CONFIG_ALLOW_CROSS=1
exec "$@"
