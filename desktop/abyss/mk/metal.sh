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
case "${1:-}" in -h|--help) sed -n '2,26p' "$0"; exit 0 ;; esac

host="${ABYSS_METAL_HOST:-}"
key="${ABYSS_METAL_KEY:-$HOME/.ssh/id_ed25519}"
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
    # shellcheck disable=SC2086
    exec ssh $opts "$user@$host" "fathom --measure"
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
  *) die "unknown command '$cmd' (ssh, report, log, fetch)" ;;
esac
