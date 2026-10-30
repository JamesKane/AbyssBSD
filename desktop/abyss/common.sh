# shellcheck shell=sh
# Shared helpers for the AbyssBSD dev/test scripts. Source this; don't run it.

# Where the desktop's binaries are (RUST.md §3.1): every script runs them
# from $ABYSS_BIN_DIR, never from a build tree by name, so a component
# changes language by changing the directory its binary is found in. The
# default is .build/abyss-bin when abyss/mk/bin-dir.sh has made it (SwiftPM's
# binaries, and Cargo's for what abyss/rust-bins names), else SwiftPM's debug
# products. The sourcing script has set $root (or $here) to the desktop.
_abyss_root=${root:-${here:-$(pwd)}}
if [ -z "${ABYSS_BIN_DIR:-}" ] && [ -d "$_abyss_root/.build/abyss-bin" ]; then
  ABYSS_BIN_DIR=$_abyss_root/.build/abyss-bin
fi
: "${ABYSS_BIN_DIR:=$_abyss_root/.build/debug}"
export ABYSS_BIN_DIR

# Make sure XDG_RUNTIME_DIR names a usable directory.
#
# Wayland needs it: the compositor creates its socket there and clients look for
# it there. A desktop Linux session gets one from pam_systemd, so this is
# invisible on the dev box — but **FreeBSD sets nothing** for an ssh or console
# login, and sway then refuses to start with "XDG_RUNTIME_DIR is not set in the
# environment. Aborting." (and `set -u` trips first). That made every live test
# fail in the build VM until this existed.
#
# The fallback is per-uid and mode 0700, which is what the spec asks of it.
abyss_ensure_runtime_dir() {
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
        return 0
    fi
    XDG_RUNTIME_DIR="${TMPDIR:-/tmp}/abyss-run-$(id -u)"
    export XDG_RUNTIME_DIR
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    echo "note: XDG_RUNTIME_DIR was unset — using $XDG_RUNTIME_DIR"
}

# Start ADE's D-Bus bridge for a test (BACKLOG D.1, PRODUCT §5.6) — a bridge,
# never a bus. Applications connect at $DBUS_SESSION_BUS_ADDRESS (exported);
# ADE's own services (abyss-dbus's portal and --menus modes, a test's probe
# service) connect at $ABYSS_BRIDGE_SERVICES. Sets $abyss_bridge_pid.
#
#   abyss_bridge_start DIR [ABYSS_DBUS]   — sockets DIR/bus, DIR/dbus-services
abyss_bridge_start() {
    _dir=$1
    _bin=${2:-$ABYSS_BIN_DIR/abyss-dbus}
    "$_bin" --endpoint --listen "$_dir/bus" --services "$_dir/dbus-services" \
        > "$_dir/bridge-endpoint.log" 2>&1 3>&- 4>&- 5>&- &
    abyss_bridge_pid=$!
    _i=0
    while ! grep -q '^ready' "$_dir/bridge-endpoint.log" 2>/dev/null && [ $_i -lt 100 ]; do sleep 0.05; _i=$((_i + 1)); done
    grep -q '^ready' "$_dir/bridge-endpoint.log" 2>/dev/null || { echo "FAIL: ADE's D-Bus bridge did not start: $(cat "$_dir/bridge-endpoint.log")"; return 1; }
    DBUS_SESSION_BUS_ADDRESS="unix:path=$_dir/bus"
    ABYSS_BRIDGE_SERVICES="unix:path=$_dir/dbus-services"
    export DBUS_SESSION_BUS_ADDRESS ABYSS_BRIDGE_SERVICES
}
