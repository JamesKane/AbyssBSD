#!/bin/sh
# AbyssBSD Swift DE — D-Bus, against GLib (PHASE8.md P8.1; BACKLOG D.1).
#
# The claim: our hand-written D-Bus implementation is correct — not
# self-consistent, correct. So **the client on the other end is never our own
# code**: `gdbus` (GLib's implementation, an entirely independent encoder) is
# the caller. A marshaller
# tested against its own parser round-trips beautifully and is still wrong
# (HANDOFF §2.37); these assertions cannot pass that way.
#
# No libdbus, no GDBus, no sd-bus in *our* binary — see PHASE8.md §4.1 for why
# all three were rejected.
#
# Usage: abyss/tests/live-dbus.sh
#
# **On ADE's bridge, not a bus** (BACKLOG D.1, PRODUCT §5.6): the probe joins as
# one of ADE's services (the private socket), GLib's `gdbus` calls it as an
# application does — and section 5 holds the bridge to its promise: an
# application cannot reach another application through it.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"

probe="$root/.build/debug/dbusprobe"
[ -x "$probe" ] && [ -x "$root/.build/debug/abyss-dbus" ] || swift build
command -v gdbus >/dev/null || { echo "FAIL: gdbus (GLib) not installed — it is the independent caller"; exit 1; }

work=$(mktemp -d /tmp/abyss-dbus.XXXXXX)
cleanup() { for p in ${sp:-} ${ap:-} ${abyss_bridge_pid:-}; do kill "$p" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

# A private bridge, so this test never touches the developer's own session.
abyss_bridge_start "$work" || exit 1
# env(1), not a prefix assignment: in POSIX sh, one before a function call can
# outlive the call and leave the whole script on the services socket.
svc() { env DBUS_SESSION_BUS_ADDRESS="$ABYSS_BRIDGE_SERVICES" "$@"; }

# ---- 1. connect + authenticate + Hello -------------------------------------
name=$(svc "$probe" hello | sed -n 's/^unique-name=//p')
case "$name" in
  :1.*) echo "ok: 1. authenticated, and the bridge assigned us $name" ;;
  *)    fail "no unique name from Hello (got '$name')" ;;
esac

# ---- 2. own a well-known name and answer a real caller ---------------------
svc "$probe" serve org.abyssbsd.Probe 20 > "$work/serve.out" 2>&1 &
sp=$!
i=0; while [ $i -lt 60 ]; do grep -q '^ready' "$work/serve.out" 2>/dev/null && break; sleep 0.1; i=$((i+1)); done
grep -q '^ready' "$work/serve.out" || fail "the probe never owned its name: $(cat "$work/serve.out")"
grep -q '^owning=org.abyssbsd.Probe' "$work/serve.out" || fail "RequestName did not make us the primary owner"
reply=$(gdbus call --session --dest org.abyssbsd.Probe --object-path / --method org.abyssbsd.Probe.Ping 2>&1)
echo "$reply" | grep -q "'pong'" || fail "gdbus did not get our reply: $reply"
reply=$(gdbus call --session --dest org.abyssbsd.Probe --object-path / --method org.abyssbsd.Probe.Echo "<'round trip'>" 2>&1)
echo "$reply" | grep -q "'round trip'" || fail "a string did not survive the round trip: $reply"
echo "ok: 2. owned org.abyssbsd.Probe as a service; gdbus, as an application, called it and read our replies"

# ---- 3. the complex types the portal API is made of -------------------------
# GLib's encoder. If our a{sv} is wrong in any way that matters, this is where
# it shows: it is the exact shape every portal method takes.
opts=$(gdbus call --session --dest org.abyssbsd.Probe --object-path / \
       --method org.abyssbsd.Probe.Echo \
       "<{'handle_token': <'abyss1'>, 'multiple': <true>, 'n': <uint32 7>}>" 2>&1)
echo "$opts" | grep -q "handle_token" || fail "an a{sv} options dict did not survive: $opts"
echo "$opts" | grep -q "uint32 7" || fail "a uint32 inside a variant did not survive: $opts"
arr=$(gdbus call --session --dest org.abyssbsd.Probe --object-path / \
      --method org.abyssbsd.Probe.Echo "<['a', 'bb', 'ccc']>" 2>&1)
echo "$arr" | grep -q "'ccc'" || fail "an array of strings did not survive: $arr"
intro=$(gdbus introspect --session --dest org.abyssbsd.Probe --object-path / 2>&1)
echo "$intro" | grep -q "org.abyssbsd.Probe" || fail "gdbus could not parse our introspection: $intro"
echo "ok: 3. gdbus round-tripped a{sv} and a nested array, and parsed our introspection"

# ---- 4. an unknown method must be ANSWERED, not ignored ---------------------
# A caller that gets no reply hangs for its full timeout with no error.
if gdbus call --session --timeout 2 --dest org.abyssbsd.Probe --object-path / \
     --method org.abyssbsd.Probe.NoSuchMethod > "$work/unk" 2>&1; then
  fail "an unknown method appeared to succeed"
fi
grep -qi 'UnknownMethod' "$work/unk" || fail "an unknown method did not get an error reply: $(cat "$work/unk")"
echo "ok: 4. an unknown method got a proper error reply, not silence"

# ---- 5. a bridge, not a bus -------------------------------------------------
# The same probe, joined as an APPLICATION, owning a name: gdbus (another
# application) cannot reach it by that name or by its unique one, cannot see
# it in ListNames, and cannot watch anything.
"$probe" serve org.abyssbsd.Other 20 > "$work/app.out" 2>&1 &
ap=$!
i=0; while [ $i -lt 60 ]; do grep -q '^ready' "$work/app.out" 2>/dev/null && break; sleep 0.1; i=$((i+1)); done
grep -q '^owning=org.abyssbsd.Other' "$work/app.out" || fail "an application could not ask for a name: $(cat "$work/app.out")"
other=$(sed -n 's/^unique-name=//p' "$work/app.out" | head -1)
if gdbus call --session --timeout 2 --dest org.abyssbsd.Other --object-path / --method org.abyssbsd.Probe.Ping > "$work/a2a" 2>&1; then
  fail "an application called another application through the bridge"
fi
grep -q 'ServiceUnknown' "$work/a2a" || fail "calling another application's name failed the wrong way: $(cat "$work/a2a")"
if [ -n "$other" ] && gdbus call --session --timeout 2 --dest "$other" --object-path / --method org.abyssbsd.Probe.Ping > "$work/a2u" 2>&1; then
  fail "an application called another application by its unique name"
fi
names=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames)
echo "$names" | grep -q 'org.abyssbsd.Other' && fail "ListNames shows an application another application asked for: $names"
echo "$names" | grep -q 'org.abyssbsd.Probe' || fail "ListNames does not show ADE's service: $names"
if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
     --method org.freedesktop.DBus.Monitoring.BecomeMonitor "[]" 0 > "$work/mon" 2>&1; then
  fail "an application became a monitor"
fi
grep -q 'AccessDenied' "$work/mon" || fail "BecomeMonitor refused the wrong way: $(cat "$work/mon")"
echo "ok: 5. a bridge, not a bus: no application reaches, lists or watches another"

wait $sp 2>/dev/null || true
grep -q '^done' "$work/serve.out" || fail "the probe did not exit cleanly: $(cat "$work/serve.out")"
echo "all green (we speak D-Bus, somebody else's implementation agrees, and the bridge is not a bus)."
