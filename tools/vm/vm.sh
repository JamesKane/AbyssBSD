#!/bin/sh
# AbyssBSD FreeBSD development VM.
#
# Fetches, provisions, and runs a FreeBSD 15.0 aarch64 guest under QEMU with
# the HVF accelerator (native speed on Apple Silicon). Phase 4 onward needs a
# real FreeBSD kernel — Capsicum, jails, pdfork, SOCK_SEQPACKET — which the
# macOS development bed cannot provide. See README.md.
set -eu

VMDIR=$(cd "$(dirname "$0")" && pwd)
cd "$VMDIR"

REL="15.0-RELEASE"
IMG="FreeBSD-15.0-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz"
URL="https://download.freebsd.org/releases/VM-IMAGES/15.0-RELEASE/aarch64/Latest/$IMG"
SHA256="e8bacaa565d5959a7408b4670947e544551ba26a4d726c04f48d025647a0cd35"

BASE="base.qcow2"
DISK="disk.qcow2"
SEED="cidata.iso"
FW_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
FW_VARS="efi-vars.fd"
CONSOLE="console.log"
PIDFILE="qemu.pid"
SSH_KEY="id_abyss_vm"
SSH_PORT=2222
CON_PORT=4555
DISK_SIZE="40G"
SMP=4
MEM=6144
REPO=$(cd "$VMDIR/../.." && pwd)
GUEST_SRC="/root/abyss"

fail() { echo "vm.sh: $1" >&2; exit 1; }

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

cmd_fetch() {
    if [ ! -f "$IMG" ]; then
        echo "downloading $IMG ..."
        curl -L --fail -o "$IMG" "$URL"
    fi
    echo "verifying checksum ..."
    got=$(shasum -a 256 "$IMG" | awk '{print $1}')
    [ "$got" = "$SHA256" ] || fail "checksum mismatch: got $got, want $SHA256"
    echo "decompressing -> $BASE ..."
    xz -dkc "$IMG" > "$BASE"
    echo "base image ready: $(qemu-img info "$BASE" | grep -i 'virtual size')"
}

cmd_seed() {
    [ -f "$SSH_KEY" ] || ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C abyssbsd-vm -q
    rm -rf cidata && mkdir cidata
    cp cloud-init/meta-data cidata/meta-data
    key=$(cat "$SSH_KEY.pub")
    awk -v k="$key" '{ gsub(/__SSH_PUBKEY__/, k); print }' \
        cloud-init/user-data > cidata/user-data
    rm -f "$SEED"
    hdiutil makehybrid -iso -joliet -default-volume-name cidata \
        -o "$SEED" cidata >/dev/null
    echo "cloud-init seed built: $SEED"
}

cmd_boot() {
    [ -f "$BASE" ] || fail "no base image — run: ./vm.sh fetch"
    running && fail "VM already running (pid $(cat "$PIDFILE"))"
    [ -f "$SEED" ] || cmd_seed
    if [ ! -f "$DISK" ]; then
        qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DISK" "$DISK_SIZE"
        echo "created overlay disk $DISK ($DISK_SIZE over $BASE)"
    fi
    : > "$CONSOLE"
    echo "booting FreeBSD $REL aarch64 (QEMU + HVF); console -> $CONSOLE"
    qemu-system-aarch64 \
        -name abyss-freebsd \
        -machine virt -accel hvf -cpu host \
        -smp "$SMP" -m "$MEM" \
        -drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
        -drive if=pflash,format=raw,file="$FW_VARS" \
        -drive if=virtio,format=qcow2,file="$DISK" \
        -drive if=virtio,format=raw,readonly=on,file="$SEED" \
        -netdev user,id=n0,hostfwd=tcp::"$SSH_PORT"-:22 \
        -device virtio-net-pci,netdev=n0 \
        -display none -monitor none \
        -chardev socket,id=con,host=127.0.0.1,port="$CON_PORT",server=on,wait=off,logfile="$CONSOLE" \
        -serial chardev:con \
        -daemonize -pidfile "$PIDFILE"
    echo "VM started (pid $(cat "$PIDFILE")). First boot runs cloud-init;"
    echo "give it a minute, then: ./vm.sh ssh"
}

cmd_ssh() {
    exec ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 \
        -p "$SSH_PORT" root@127.0.0.1 "$@"
}

cmd_sync() {
    running || fail "VM is not running — ./vm.sh boot"
    command -v rsync >/dev/null 2>&1 || fail "rsync is not on the host PATH"
    echo "syncing $REPO/ -> VM:$GUEST_SRC/ ..."
    rsync -az --delete \
        --exclude .git --exclude target --exclude tools --exclude site \
        -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $SSH_PORT" \
        "$REPO/" "root@127.0.0.1:$GUEST_SRC/"
    echo "synced."
}

cmd_build() {
    cmd_sync
    echo "running cargo xtask ci in the VM ..."
    cmd_ssh "cd $GUEST_SRC && cargo xtask ci"
}

# The packages a clean VM needs to build and test the workspace: the Rust
# toolchain, git, the abyss-font stack (pkgconf + freetype2 + harfbuzz),
# the dejavu font the abyss-font tests open, rsync for `sync`, and libdrm
# for the DRM/KMS user-space ABI headers the Phase-5 compositor uses
# (docs/design/drm-kms-bringup.md §6 — sys/drm-sys includes <libdrm/drm.h>
# and <libdrm/drm_mode.h>; the shim does not link libdrm.so).
cmd_provision() {
    running || fail "VM is not running — ./vm.sh boot"
    echo "installing build and test packages in the VM ..."
    cmd_ssh "env ASSUME_ALWAYS_YES=YES pkg bootstrap -f && \
        env ASSUME_ALWAYS_YES=YES pkg install -y \
        rust git pkgconf freetype2 harfbuzz dejavu rsync libdrm"
}

cmd_stop() {
    running || fail "VM is not running"
    pid=$(cat "$PIDFILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "stopped VM (pid $pid)"
}

cmd_reset() {
    running && fail "stop the VM first: ./vm.sh stop"
    rm -f "$DISK" "$FW_VARS"
    cp /opt/homebrew/share/qemu/edk2-arm-vars.fd "$FW_VARS"
    echo "reset: removed overlay disk; next boot starts from a fresh $BASE"
}

cmd_status() {
    if running; then
        echo "running (pid $(cat "$PIDFILE")), ssh on port $SSH_PORT"
    else
        echo "not running"
    fi
}

case "${1:-}" in
    fetch)  cmd_fetch ;;
    seed)   cmd_seed ;;
    boot)   cmd_boot ;;
    ssh)    shift 2>/dev/null || true; cmd_ssh "$@" ;;
    provision) cmd_provision ;;
    sync)   cmd_sync ;;
    build)  cmd_build ;;
    stop)   cmd_stop ;;
    reset)  cmd_reset ;;
    status) cmd_status ;;
    *)
        echo "usage: vm.sh {fetch|seed|boot|ssh|provision|sync|build|stop|reset|status}" >&2
        exit 1
        ;;
esac
