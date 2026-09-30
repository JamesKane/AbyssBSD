#!/bin/sh
# Boot the AbyssBSD build VM (qemu + KVM, headless, serial-logged).
# Creates a copy-on-write overlay disk on first run so the pristine base image
# is never mutated. Re-run to reset: `rm $ABYSS_DISK` then run again.
set -eu
. "$(dirname "$0")/config.sh"

[ -f "$ABYSS_BASE_QCOW" ] || { echo "base image missing; run fetch-image.sh first" >&2; exit 1; }
[ -f "$ABYSS_SEED" ]      || { echo "seed missing; run make-seed.sh first" >&2; exit 1; }

# First boot: create a resized COW overlay backed by the pristine image.
if [ ! -f "$ABYSS_DISK" ]; then
  echo "[run] creating overlay disk $ABYSS_DISK ($ABYSS_DISK_SIZE)"
  qemu-img create -f qcow2 -F qcow2 -b "$ABYSS_BASE_QCOW" "$ABYSS_DISK" >/dev/null
  qemu-img resize "$ABYSS_DISK" "$ABYSS_DISK_SIZE" >/dev/null
fi

# The Phase-5 scratch disk: the thing an install test is allowed to destroy.
if [ ! -f "$ABYSS_SCRATCH" ]; then
  echo "[run] creating scratch disk $ABYSS_SCRATCH ($ABYSS_SCRATCH_SIZE)"
  qemu-img create -f qcow2 "$ABYSS_SCRATCH" "$ABYSS_SCRATCH_SIZE" >/dev/null
fi

serial_log="$ABYSS_VM_HOME/serial.log"
echo "[run] booting $ABYSS_HOSTNAME  (ssh: port $ABYSS_SSH_PORT, serial: $serial_log)"
echo "[run] Ctrl-A X to quit the console; or run with ABYSS_DAEMON=1 for background."

set -- \
  -name "$ABYSS_HOSTNAME" \
  -machine q35,accel=kvm -cpu host -smp "$ABYSS_CPUS" -m "$ABYSS_MEM" \
  -drive file="$ABYSS_DISK",if=virtio,format=qcow2,cache=writeback \
  -drive file="$ABYSS_SEED",if=virtio,format=raw,readonly=on \
  -drive file="$ABYSS_SCRATCH",if=virtio,format=qcow2,cache=writeback \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$ABYSS_SSH_PORT"-:22 \
  -device virtio-net,netdev=net0 \
  -display none

if [ "${ABYSS_DAEMON:-0}" = "1" ]; then
  : > "$serial_log"
  # Console (ttyu0) -> log file; run detached.
  qemu-system-x86_64 "$@" -serial "file:$serial_log" -monitor none \
    -daemonize -pidfile "$ABYSS_VM_HOME/qemu.pid"
  echo "[run] daemonized; pid $(cat "$ABYSS_VM_HOME/qemu.pid")"
else
  # Console (ttyu0) -> this terminal, with QEMU monitor multiplexed (Ctrl-A C).
  exec qemu-system-x86_64 "$@" -serial mon:stdio
fi
