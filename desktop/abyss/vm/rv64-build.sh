#!/bin/sh
# Build FreeBSD/riscv64 packages on the builder VM (RUST.md R0, §6.9):
# FreeBSD builds none for riscv64, so the desktop's are ours. Cross, with
# native-xtools: the compilers run on amd64, qemu-user-static runs what a
# build executes.
#
#   abyss/vm/rv64-build.sh            # jail if missing, then the bulk
#
# The jail `rv64` is our src/ fork built for riscv64 (about 1h30 on 12
# cores the first time). The make.conf beside this script is what the
# riscv64 set needs to build (RUST.md §5); rv64-ports.list is what to
# build. Afterwards, rv64-sysroot.sh brings the result to the host.
set -eu
ABYSS_VM_ROLE=builder
. "$(dirname "$0")/config.sh"
# shellcheck disable=SC2046
bssh() { ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$@"; }
src=$ABYSS_GUEST_SRC/src

bssh 'sudo tee /usr/local/etc/poudriere.d/rv64-make.conf >/dev/null' < "$ABYSS_VM_DIR/rv64-make.conf"
bssh 'cat > ~/rv64-ports.list' < "$ABYSS_VM_DIR/rv64-ports.list"
bssh 'sudo sysrc qemu_user_static_enable=YES >/dev/null; sudo service qemu_user_static onestart >/dev/null 2>&1 || true' </dev/null

if ! bssh 'poudriere jail -l -q | grep -q "^rv64 "' </dev/null; then
  echo "[rv64] creating the rv64 jail from $src (long)"
  bssh "sudo poudriere jail -c -j rv64 -a riscv.riscv64 -m src=$src -b -x -J $ABYSS_CPUS" </dev/null
fi
echo "[rv64] bulk"
bssh "sudo poudriere bulk -j rv64 -p default -J 4 -f ~/rv64-ports.list" </dev/null
