#!/bin/sh
# Talk to the bring-up machine instead of photographing it (PHASE4 §5.8).
#
# Every pass from P4.4 on has had a human boot cycle in it, and the loop has
# been: build an image, write a stick, walk to the machine, boot it, read the
# screen, photograph it, walk back, type it in. Three of the last four findings
# on that machine were read off a phone camera — including one where the useful
# line had scrolled off.
#
# **This does not make the machine part of the test suite**, and it must not:
# `abyss/tests/run.sh` stays hermetic, and nothing in it may depend on a
# particular desktop being switched on. What this shortens is the *diagnostic*
# loop, which is a person's time, not the gate.
#
#   abyss/mk/metal.sh ssh [cmd...]     run a command there, or open a shell
#   abyss/mk/metal.sh report           fathom --measure, straight to this screen
#   abyss/mk/metal.sh fetch REMOTE [LOCAL]
#   abyss/mk/metal.sh log              tail the live session's log
#   abyss/mk/metal.sh push [--no-build]
#                                      build in the VM, put the build on the
#                                      machine, restart its session
#   abyss/mk/metal.sh stop | start | restart
#                                      the live session, and its root helpers
#
# Configure with ABYSS_METAL_HOST (an address or a name) and, if it is not the
# default, ABYSS_METAL_KEY. The medium prints its address on the console at boot.
#
# **The medium only answers if it was built with `--ssh-key`**, which is a
# developer build: root there has no password, so a default medium deliberately
# runs no sshd at all and `live-medium.sh` asserts it.
set -eu

# --help before anything else, so asking how it works never demands a machine to
# ask it about. (write-stick.sh's rule, for the same reason.)
case "${1:-}" in -h|--help) sed -n '2,/^[^#]/{/^#/p;}' "$0"; exit 0 ;; esac

# Where the project keeps keys for machines it talks to — outside the repo, so
# a private key cannot be committed, and beside the VM's own. A separate key
# from the VM's on purpose: the bring-up machine is somebody's desk, and the two
# should be revocable independently.
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
ABYSS_VM_DIR="$root_dir/abyss/vm"; export ABYSS_VM_DIR
. "$root_dir/abyss/vm/config.sh"

host="${ABYSS_METAL_HOST:-}"
key="${ABYSS_METAL_KEY:-$ABYSS_VM_HOME/id_metal}"
user="${ABYSS_METAL_USER:-root}"

die() { echo "metal: $1" >&2; exit 1; }

[ -n "$host" ] || die "set ABYSS_METAL_HOST to the address the medium printed on its console"
[ -r "$key" ] || die "no readable private key at $key (set ABYSS_METAL_KEY)"

# The same options the VM harness uses, and for the same reasons: key only, so a
# misconfigured medium fails fast instead of prompting; and no known_hosts,
# because the medium regenerates its host key on every boot and a warning there
# would be noise about a machine that is meant to be disposable.
opts="-i $key -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
-o ConnectTimeout=10"

# The live session: rc's `abyss_live` starts the root helpers, then the session
# as the live user. Stopping it means all of them, because a fresh start runs
# the helpers again and two of each would fight over their sockets.
metal_stop() {
  echo "metal: stopping the live session on $host"
  ssh $opts "$user@$host" 'pkill -x anchor undertow abyss-install abyss-settings 2>/dev/null; \
    i=0; while pgrep -x anchor undertow abyss-install abyss-settings >/dev/null && [ $i -lt 50 ]; do \
      i=$((i+1)); sleep 0.1; done; \
    pkill -9 -x anchor undertow abyss-install abyss-settings 2>/dev/null; true'
}
metal_start() {
  echo "metal: starting the live session on $host (its log: metal.sh log)"
  # rc's own entry point, so a restarted session is started the way a booted
  # one was. Under daemon(8), detached from this ssh session, so closing the
  # connection cannot hang it up.
  ssh $opts "$user@$host" 'daemon -f service abyss_live start'
}

cmd="${1:-ssh}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  ssh)
    # shellcheck disable=SC2086
    exec ssh $opts "$user@$host" "$@"
    ;;
  report)
    # The whole point of the exercise: the report on this screen, in one command,
    # with no stick and no camera.
    #
    # **The measurement needs the display, and the live session holds it**
    # (DRM master): fathom's own undertow cannot open the card while the
    # desktop is up. So a running session is set aside for the measurement and
    # brought back after it. And a runtime directory is made for it, because
    # an ssh login on FreeBSD gets none (no pam_xdg, HANDOFF §2.31).
    # shellcheck disable=SC2086
    running=$(ssh $opts "$user@$host" 'pgrep -x undertow >/dev/null && echo yes || true')
    [ "$running" = yes ] && metal_stop
    rc=0
    # shellcheck disable=SC2086
    ssh $opts "$user@$host" 'd=/var/run/fathom-metal; mkdir -p $d && chmod 700 $d; \
      XDG_RUNTIME_DIR=$d fathom --measure' || rc=$?
    [ "$running" = yes ] && metal_start
    exit $rc
    ;;
  log)
    # shellcheck disable=SC2086
    exec ssh $opts "$user@$host" "cat /var/log/abyss-live.log"
    ;;
  fetch)
    [ $# -ge 1 ] || die "usage: metal.sh fetch REMOTE [LOCAL]"
    remote=$1
    local_path="${2:-$(basename "$remote")}"
    # shellcheck disable=SC2086
    scp $opts "$user@$host:$remote" "$local_path"
    echo "metal: $local_path"
    ;;
  stop)
    metal_stop
    ;;
  start)
    metal_start
    ;;
  restart)
    metal_stop
    metal_start
    ;;
  push)
    # **Update the stick in place, instead of writing a new one.** The medium's
    # root is read-write UFS and the desktop is a plain tree under /usr/local
    # (the same files `abyss.tzst` carries), so a new build is new files and a
    # restarted session. A new *stick* is only owed when the base, the
    # libraries or the medium's own scripts change — and the ldd check below
    # says when the first two have.
    if [ "${1:-}" != --no-build ]; then
      "$root_dir/abyss/vm/build.sh" --no-test || die "the build failed in the VM"
    fi
    . "$root_dir/abyss/mk/desktop-files.sh"
    # One line: the list spans several, and a newline inside a remote command
    # string ends that command there.
    BINARIES=$(echo $BINARIES); DATA_DIRS=$(echo $DATA_DIRS)
    # shellcheck disable=SC2046
    guest() { ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$@"; }
    there() { ssh $opts "$user@$host" "$@"; }
    guest "cd $ABYSS_GUEST_SRC/.build/debug && ls $BINARIES" >/dev/null \
      || die "the VM has no build of one of: $BINARIES"
    # Stopped first: FreeBSD will not let a running executable be overwritten
    # (ETXTBSY), and a half-replaced session is worse than a stopped one.
    metal_stop
    # Guest to machine through this host: the machine's key never leaves it.
    echo "metal: binaries -> $host:/usr/local/bin"
    guest "cd $ABYSS_GUEST_SRC/.build/debug && tar -cf - $BINARIES" \
      | there "tar -xpf - -C /usr/local/bin"
    echo "metal: $DATA_DIRS -> $host:/usr/local/share/abyss"
    there "cd /usr/local/share/abyss && rm -rf $DATA_DIRS"
    guest "cd $ABYSS_GUEST_SRC && tar -cf - $DATA_DIRS" \
      | there "tar -xpf - -C /usr/local/share/abyss"
    # **A build the stick cannot run is a new stick, not a push.** Say so here,
    # before a session fails to start for a reason buried in its log.
    missing=$(there "for b in $BINARIES; do ldd /usr/local/bin/\$b 2>/dev/null | grep 'not found'; done | sort -u")
    if [ -n "$missing" ]; then
      echo "$missing" >&2
      die "this build needs libraries the stick does not carry — rebuild the medium (live-image.sh --ssh-key)"
    fi
    metal_start
    ;;
  *) die "unknown command '$cmd' (ssh, report, log, fetch, push, stop, start, restart)" ;;
esac
