#!/bin/sh
# Provision the riscv64 guest over its console (no cloud-init on riscv64);
# see provision-rv64.py. The guest must be running with ABYSS_DAEMON=1.
#
#   provision-rv64.sh        both phases: the base, then pkg if there is a
#                            repository (rv64-sysroot.sh makes it)
#   provision-rv64.sh pkg    the pkg phase only: (re)install from the repository
set -eu
ABYSS_VM_ROLE=${ABYSS_VM_ROLE:-rv64}
. "$(dirname "$0")/config.sh"
[ "$ABYSS_ARCH" = riscv64 ] || { echo "provision-rv64.sh: ABYSS_VM_ROLE=rv64 only" >&2; exit 2; }
[ -S "$ABYSS_CONSOLE_SOCK" ] || { echo "no console socket; boot with ABYSS_DAEMON=1 ./run.sh" >&2; exit 1; }

prov() {
  python3 "$ABYSS_VM_DIR/provision-rv64.py" \
    "$ABYSS_CONSOLE_SOCK" "$ABYSS_SSH_USER" "$ABYSS_HOSTNAME" "$ABYSS_SSH_KEY.pub" "$1"
}

[ "${1:-}" = pkg ] || prov base

if [ ! -d "$ABYSS_RV64_PKGS/All" ]; then
  echo "[provision] no package repository at $ABYSS_RV64_PKGS: run rv64-sysroot.sh, then provision-rv64.sh pkg"
  exit 0
fi
echo "[provision] copying the package repository in"
# shellcheck disable=SC2046
tar -C "$ABYSS_RV64_PKGS" -cf - . \
  | ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@$ABYSS_SSH_HOST" 'rm -rf ~/pkgs && mkdir ~/pkgs && tar -xf - -C ~/pkgs'
prov pkg
