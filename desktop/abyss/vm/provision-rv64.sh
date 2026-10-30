#!/bin/sh
# Provision the riscv64 guest over its console (no cloud-init on riscv64);
# see provision-rv64.py. The guest must be running with ABYSS_DAEMON=1.
set -eu
ABYSS_VM_ROLE=${ABYSS_VM_ROLE:-rv64}
. "$(dirname "$0")/config.sh"
[ "$ABYSS_ARCH" = riscv64 ] || { echo "provision-rv64.sh: ABYSS_VM_ROLE=rv64 only" >&2; exit 2; }
[ -S "$ABYSS_CONSOLE_SOCK" ] || { echo "no console socket; boot with ABYSS_DAEMON=1 ./run.sh" >&2; exit 1; }
exec python3 "$ABYSS_VM_DIR/provision-rv64.py" \
  "$ABYSS_CONSOLE_SOCK" "$ABYSS_SSH_USER" "$ABYSS_HOSTNAME" "$ABYSS_SSH_KEY.pub"
