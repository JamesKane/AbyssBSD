#!/bin/sh
# SSH into the build VM. Extra args are passed through to ssh (e.g. a command).
set -eu
. "$(dirname "$0")/config.sh"
# shellcheck disable=SC2046
exec ssh $(abyss_ssh_opts) "$ABYSS_SSH_USER@127.0.0.1" "$@"
