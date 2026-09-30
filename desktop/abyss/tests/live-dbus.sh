#!/bin/sh
# AbyssBSD Swift DE — D-Bus, against a real bus (PHASE8.md P8.1).
#
# The claim: our hand-written D-Bus implementation is correct — not
# self-consistent, correct. So **the client on the other end is never our own
# code**. `dbus-daemon` is the bus, and `dbus-send` and `gdbus` (GLib's
# implementation, an entirely independent encoder) are the callers. A marshaller
# tested against its own parser round-trips beautifully and is still wrong
# (HANDOFF §2.37); these assertions cannot pass that way.
#
# No libdbus, no GDBus, no sd-bus in *our* binary — see PHASE8.md §4.1 for why
# all three were rejected.
#
# Usage: abyss/tests/live-dbus.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

probe="$root/.build/debug/dbusprobe"
[ -x "$probe" ] || swift build

command -v dbus-run-session >/dev/null \
  || { echo "FAIL: dbus-run-session not installed"; exit 1; }
command -v dbus-send >/dev/null || { echo "FAIL: dbus-send not installed"; exit 1; }

work=$(mktemp -d /tmp/abyss-dbus.XXXXXX)
trap 'rm -rf "$work"' EXIT

# Everything runs inside one private session bus, so this test can never touch
# the developer's own bus or be affected by what is on it.
dbus-run-session -- sh -s "$probe" "$work" <<'SESSION' > "$work/out" 2>&1
set -eu
probe=$1
work=$2

# ---- 1. connect + authenticate + Hello -------------------------------------
name=$("$probe" hello | sed -n 's/^unique-name=//p')
case "$name" in
  :1.*) echo "ok: authenticated and the bus assigned us $name" ;;
  *)    echo "FAIL: no unique name from Hello (got '$name')"; exit 1 ;;
esac

# ---- 2. own a well-known name and answer real callers -----------------------
"$probe" serve org.abyssbsd.Probe 10 > "$work/serve.out" 2>&1 &
sp=$!
i=0
while [ $i -lt 60 ]; do grep -q '^ready' "$work/serve.out" 2>/dev/null && break; sleep 0.1; i=$((i+1)); done
grep -q '^ready' "$work/serve.out" \
  || { echo "FAIL: the probe never owned its name"; cat "$work/serve.out"; exit 1; }
grep -q '^owning=org.abyssbsd.Probe' "$work/serve.out" \
  || { echo "FAIL: RequestName did not make us the primary owner"; exit 1; }
echo "ok: owned org.abyssbsd.Probe as primary owner"

# dbus-send: a different implementation entirely.
reply=$(dbus-send --session --print-reply --dest=org.abyssbsd.Probe / \
        org.abyssbsd.Probe.Ping 2>&1)
echo "$reply" | grep -q '"pong"' \
  || { echo "FAIL: dbus-send did not get our reply"; echo "$reply"; exit 1; }
echo "ok: dbus-send called us and read our reply"

# A string echoed back through their encoder and ours.
reply=$(dbus-send --session --print-reply --dest=org.abyssbsd.Probe / \
        org.abyssbsd.Probe.Echo string:"round trip" 2>&1)
echo "$reply" | grep -q '"round trip"' \
  || { echo "FAIL: string did not survive the round trip"; echo "$reply"; exit 1; }
echo "ok: a string survived their encoder and our decoder"

# ---- 3. the complex types the portal API is made of -------------------------
# gdbus is GLib's implementation. If our a{sv} is wrong in any way that matters,
# this is where it shows: it is the exact shape every portal method takes.
if command -v gdbus >/dev/null; then
  opts=$(gdbus call --session --dest org.abyssbsd.Probe --object-path / \
         --method org.abyssbsd.Probe.Echo \
         "<{'handle_token': <'abyss1'>, 'multiple': <true>, 'n': <uint32 7>}>" 2>&1)
  echo "$opts" | grep -q "handle_token" \
    || { echo "FAIL: an a{sv} options dict did not survive"; echo "$opts"; exit 1; }
  echo "$opts" | grep -q "uint32 7" \
    || { echo "FAIL: a uint32 inside a variant did not survive"; echo "$opts"; exit 1; }
  echo "ok: gdbus round-tripped a{sv} — the portal's options dictionary"

  arr=$(gdbus call --session --dest org.abyssbsd.Probe --object-path / \
        --method org.abyssbsd.Probe.Echo "<['a', 'bb', 'ccc']>" 2>&1)
  echo "$arr" | grep -q "'ccc'" \
    || { echo "FAIL: an array of strings did not survive"; echo "$arr"; exit 1; }
  echo "ok: gdbus round-tripped a nested array"

  # They parse our introspection XML with their own parser.
  intro=$(gdbus introspect --session --dest org.abyssbsd.Probe --object-path / 2>&1)
  echo "$intro" | grep -q "org.abyssbsd.Probe" \
    || { echo "FAIL: gdbus could not parse our introspection"; echo "$intro"; exit 1; }
  echo "ok: gdbus parsed our introspection XML"
else
  echo "note: gdbus not installed — skipped the a{sv} checks"
fi

# ---- 4. an unknown method must be ANSWERED, not ignored ---------------------
# A caller that gets no reply hangs for its full timeout with no error. This is
# the same failure shape as a missing xdg-shell configure (PHASE6 P6.3).
if dbus-send --session --print-reply --reply-timeout=2000 \
     --dest=org.abyssbsd.Probe / org.abyssbsd.Probe.NoSuchMethod > "$work/unk" 2>&1; then
  echo "FAIL: an unknown method appeared to succeed"; exit 1
fi
grep -qi 'UnknownMethod' "$work/unk" \
  || { echo "FAIL: an unknown method did not produce an error reply"
       echo "      (a caller with no reply hangs for its whole timeout)"
       cat "$work/unk"; exit 1; }
echo "ok: an unknown method got a proper error reply, not silence"

wait $sp 2>/dev/null || true
grep -q '^done' "$work/serve.out" \
  || { echo "FAIL: the probe did not exit cleanly"; cat "$work/serve.out"; exit 1; }
echo "ok: served throughout and shut down cleanly"
SESSION

cat "$work/out"
grep -q '^FAIL' "$work/out" && exit 1
echo "all green (we speak D-Bus, and somebody else's implementation agrees)."
