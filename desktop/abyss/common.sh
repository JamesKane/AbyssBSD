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
