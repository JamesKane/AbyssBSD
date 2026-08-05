#!/bin/sh
# Regenerate the Wayland protocol client glue committed into the CWayland target.
# Run from anywhere; paths are resolved relative to the repo root.
#
# Phase 1 generates xdg-shell only. To add a protocol, drop its XML in
# protocols/ and add a line below; the generated .h goes in include/, the .c
# alongside this script (and must be listed in Package.swift's CWayland sources).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
proto="$root/protocols"

gen() {
    name=$1
    xml="$proto/$name.xml"
    echo "scanner: $name"
    wayland-scanner client-header "$xml" "$here/include/$name-client-protocol.h"
    wayland-scanner private-code  "$xml" "$here/$name-protocol.c"
}

# Server-side headers, for the compositor (PHASE6.md P6.2). wlroots' own headers
# `#include "xdg-shell-protocol.h"` — the SERVER header, which this repo had
# never generated because everything until Phase 6 was a client. A naive
# `import CWlroots` fails on exactly that missing file and the error names the
# header rather than the cause, so it is worth knowing.
#
# Note there is no `private-code` here: wlroots links the protocol
# implementations itself. We generate only the header its headers need.
gen_server() {
    name=$1
    xml="$proto/$name.xml"
    echo "scanner: $name (server)"
    wayland-scanner server-header "$xml" "$root/de/cwlroots/include/$name-protocol.h"
}

gen xdg-shell
gen wlr-layer-shell-unstable-v1
gen wlr-foreign-toplevel-management-unstable-v1
gen xdg-activation-v1
gen wlr-screencopy-unstable-v1

gen_server xdg-shell
gen_server wlr-layer-shell-unstable-v1

echo "done."
