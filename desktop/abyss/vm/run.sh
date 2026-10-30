#!/bin/sh
# Boot an AbyssBSD VM (qemu + KVM, or TCG for riscv64; headless, serial-logged).
# Creates a copy-on-write overlay disk on first run so the pristine base image
# is never mutated. Re-run to reset: `rm $ABYSS_DISK` then run again.
set -eu
. "$(dirname "$0")/config.sh"

if [ "$ABYSS_VMM" = bhyve ]; then
  # On the FreeBSD box (config.sh): send bhyve-run.sh there, start the VM,
  # and record the address its DHCP lease gives it, for ssh.sh and the rest.
  h=$ABYSS_BHYVE_HOST
  name=abyss${_role:--build}$_suffix
  ssh -o BatchMode=yes "$h" "mkdir -p $ABYSS_BHYVE_HOME"
  scp -q -o BatchMode=yes "$ABYSS_VM_DIR/bhyve-run.sh" "$h:$ABYSS_BHYVE_HOME/bhyve-run.sh"
  ssh -o BatchMode=yes "$h" "sh $ABYSS_BHYVE_HOME/bhyve-run.sh $name $ABYSS_BHYVE_CPUS $ABYSS_BHYVE_MEM \
    $ABYSS_BHYVE_DISK $ABYSS_BHYVE_TAP $ABYSS_BHYVE_MAC"
  log=$ABYSS_BHYVE_HOME/serial-$name.log
  echo "[run] waiting for $name's DHCP lease (console: $h:$log)"
  ip=""
  for _ in $(seq 120); do
    ip=$(ssh -o BatchMode=yes "$h" "sed -n 's/.*bound to \([0-9.]*\) .*/\1/p' $log | tail -1")
    [ -n "$ip" ] && break
    sleep 5
  done
  [ -n "$ip" ] || { echo "[run] no lease in 10 minutes; see $h:$log" >&2; exit 1; }
  echo "$ip" > "$ABYSS_VM_HOME/ip$_role$_suffix"
  echo "[run] $name is at $ip (ssh.sh reaches it)"
  exit 0
fi

[ -f "$ABYSS_BASE_QCOW" ] || { echo "base image missing; run fetch-image.sh first" >&2; exit 1; }
# The riscv64 guest has no seed: provision-rv64.py sets it up over the console.
[ "$ABYSS_ARCH" = riscv64 ] || [ -f "$ABYSS_SEED" ] || { echo "seed missing; run make-seed.sh first" >&2; exit 1; }

# First boot: create a resized COW overlay backed by the pristine image.
if [ ! -f "$ABYSS_DISK" ]; then
  echo "[run] creating overlay disk $ABYSS_DISK ($ABYSS_DISK_SIZE)"
  qemu-img create -f qcow2 -F qcow2 -b "$ABYSS_BASE_QCOW" "$ABYSS_DISK" >/dev/null
  qemu-img resize "$ABYSS_DISK" "$ABYSS_DISK_SIZE" >/dev/null
fi

# The Phase-5 scratch disk: the thing an install test is allowed to destroy.
# The builder has none (ABYSS_SCRATCH=none).
if [ "$ABYSS_SCRATCH" != none ] && [ ! -f "$ABYSS_SCRATCH" ]; then
  echo "[run] creating scratch disk $ABYSS_SCRATCH ($ABYSS_SCRATCH_SIZE)"
  qemu-img create -f qcow2 "$ABYSS_SCRATCH" "$ABYSS_SCRATCH_SIZE" >/dev/null
fi

serial_log="$ABYSS_SERIAL_LOG"
echo "[run] booting $ABYSS_HOSTNAME  (ssh: port $ABYSS_SSH_PORT, serial: $serial_log)"
echo "[run] Ctrl-A X to quit the console; or run with ABYSS_DAEMON=1 for background."

if [ "$ABYSS_ARCH" = riscv64 ]; then
  # EDK2 on the virt machine's pflash (OpenSBI is qemu's default -bios), then
  # FreeBSD's loader.efi. The virt machine's flash banks are 32M each and
  # Fedora ships the images unpadded, so both are copies padded to size; the
  # variable store's copy is also the guest's private, writable one.
  code="$ABYSS_VM_HOME/rv64-code.fd"
  if [ ! -f "$code" ]; then
    cp "$ABYSS_RV64_FW_CODE" "$code" && truncate -s 32M "$code"
  fi
  if [ ! -f "$ABYSS_RV64_VARS" ]; then
    cp "$ABYSS_RV64_FW_VARS" "$ABYSS_RV64_VARS" && truncate -s 32M "$ABYSS_RV64_VARS"
  fi
  qemu=qemu-system-riscv64
  set -- \
    -name "$ABYSS_HOSTNAME" \
    -machine virt,acpi=off -accel tcg,thread=multi -cpu "$ABYSS_RV64_CPU" \
    -smp "$ABYSS_CPUS" -m "$ABYSS_MEM" \
    -drive if=pflash,unit=0,format=raw,readonly=on,file="$code" \
    -drive if=pflash,unit=1,format=raw,file="$ABYSS_RV64_VARS" \
    -drive file="$ABYSS_DISK",if=none,id=hd0,format=qcow2,cache=writeback \
    -device virtio-blk-device,drive=hd0 \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$ABYSS_SSH_PORT"-:22 \
    -device virtio-net-device,netdev=net0 \
    -device virtio-rng-device \
    -display none
else
  qemu=qemu-system-x86_64
  set -- \
    -name "$ABYSS_HOSTNAME" \
    -machine q35,accel=kvm -cpu host -smp "$ABYSS_CPUS" -m "$ABYSS_MEM" \
    -drive file="$ABYSS_DISK",if=virtio,format=qcow2,cache=writeback \
    -drive file="$ABYSS_SEED",if=virtio,format=raw,readonly=on \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$ABYSS_SSH_PORT"-:22 \
    -device virtio-net,netdev=net0 \
    -display none
fi
[ "$ABYSS_SCRATCH" != none ] && set -- "$@" -drive file="$ABYSS_SCRATCH",if=virtio,format=qcow2,cache=writeback

if [ "${ABYSS_DAEMON:-0}" = "1" ]; then
  : > "$serial_log"
  if [ "$ABYSS_ARCH" = riscv64 ]; then
    # The console is a socket as well as a log, so provision-rv64.py can type
    # at it: no cloud-init here.
    rm -f "$ABYSS_CONSOLE_SOCK"
    set -- "$@" -chardev socket,id=con,path="$ABYSS_CONSOLE_SOCK",server=on,wait=off,logfile="$serial_log" \
      -serial chardev:con
  else
    # Console (ttyu0) -> log file; run detached.
    set -- "$@" -serial "file:$serial_log"
  fi
  "$qemu" "$@" -monitor none -daemonize -pidfile "$ABYSS_PIDFILE"
  echo "[run] daemonized; pid $(cat "$ABYSS_PIDFILE")"
else
  # Console (ttyu0) -> this terminal, with QEMU monitor multiplexed (Ctrl-A C).
  exec "$qemu" "$@" -serial mon:stdio
fi
