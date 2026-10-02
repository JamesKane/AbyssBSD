# shellcheck shell=sh
# Shared helpers for the AbyssBSD dev/test scripts. Source this; don't run it.

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
    _bin=${2:-$(cd "$(dirname "${0}")/../.." && pwd)/.build/debug/abyss-dbus}
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
