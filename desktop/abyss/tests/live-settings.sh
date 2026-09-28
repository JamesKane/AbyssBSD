#!/bin/sh
# AbyssBSD Swift DE — the settings helper, as a service (PHASE14 P14.3).
#
# `abyss-settings` (root) commanded by `abyss-settingsctl` (this user), over
# CurrentIPC, exactly as System Preferences will command it. Claims:
#
#   1. it admits the uid it was started for, and only while that uid is an
#      administrator — a stranger and a non-administrator are each refused, in
#      words (§6.1);
#   2. `check` shows the exact commands a plan compiles to, running nothing;
#   3. a dry run reports every step and writes nothing; the journal records it;
#   4. on Linux, a real read or apply is REFUSED, and says why (§6.4) — the
#      positive control that the refusal exists;
#   5. on FreeBSD, as root, a real apply to a scratch rc.conf writes it with
#      sysrc — and read agrees afterwards — without touching /etc/rc.conf;
#   6. network (P14.4): an interface this machine lacks, and a bad address, are
#      refused in words; on FreeBSD, check and a dry run on the guest's own
#      interface, then a WRITE-ONLY apply — rc.conf and resolvconf.conf written
#      for real (scratch copies), netif/routing/resolvconf skipped and said to
#      be, because this guest's network is how the test reaches it (§6.3).
#   7. sound (P14.6b): a device the machine lacks, and a name that is no
#      device, refused in words; on FreeBSD, with snd_dummy, the default read
#      from the kernel, a write-only apply writing a scratch sysctl.conf, and a
#      real one as root — to the unit it already is, so the guest is unchanged
#      and the sysctl step is seen to run.
#
# Usage: abyss/tests/live-settings.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

helper="$root/.build/debug/abyss-settings"
ctl="$root/.build/debug/abyss-settingsctl"
[ -x "$helper" ] && [ -x "$ctl" ] || swift build

work=$(mktemp -d /tmp/abyss-settings.XXXXXX)
chmod 755 "$work"                       # a root helper writes here, as well as us
cleanup() {
  [ -n "${svc_pid:-}" ] && { $sudo kill "$svc_pid" 2>/dev/null || true; }
  $sudo rm -rf "$work" 2>/dev/null || rm -rf "$work"
}
fail() { echo "FAIL: $1"; [ -s "$work/svc.err" ] && sed 's/^/  helper| /' "$work/svc.err"; exit 1; }
trap cleanup EXIT INT TERM HUP

me=$(id -u)
mygroup=$(id -gn)
freebsd=0; [ "$(uname -s)" = FreeBSD ] && freebsd=1
sudo=""
if [ "$freebsd" = 1 ]; then
  sudo -n true 2>/dev/null || fail "on FreeBSD this test runs the helper as root, and needs passwordless sudo"
  sudo=sudo
fi
rundir="$work/run"; mkdir -p "$rundir"; chmod 700 "$rundir"
export ABYSS_RUNTIME_DIR="$rundir"

serve() {  # serve [HELPER OPTIONS…] — start it, wait for its socket
  if [ -n "${svc_pid:-}" ]; then $sudo kill "$svc_pid" 2>/dev/null || true; wait "$svc_pid" 2>/dev/null || true; fi
  $sudo rm -f "$rundir/settings.sock"
  $sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --rc-conf "$work/rc.conf" \
      --resolvconf "$work/resolvconf.conf" --sysctl-conf "$work/sysctl.conf" \
      --journal "$work/journal" "$@" 2> "$work/svc.err" &
  svc_pid=$!
  i=0
  while [ ! -S "$rundir/settings.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$rundir/settings.sock" ] || fail "the helper never came up: $(cat "$work/svc.err")"
}
ctlrun() {  # ctlrun ARGS… -> stdout+stderr in $out, status in $rc
  rc=0; out=$("$ctl" "$@" 2>&1) || rc=$?
}
echo 'hostname="abyss"' > "$work/rc.conf"
chmod 644 "$work/rc.conf"
original=$(cat "$work/rc.conf")

# ---------------------------------------------------------------- 1. who
# The socket is handed to one uid, so a stranger is stopped by its permissions
# before the helper hears a word. The caller who gets past permissions is root
# — so root is the stranger that tests the peer check. Where sudo is.
if [ -n "$sudo" ]; then
  serve --uid "$me" --admin-group "$mygroup"
  rc=0; out=$(sudo env ABYSS_RUNTIME_DIR="$rundir" "$ctl" read energy 2>&1) || rc=$?
  [ "$rc" != 0 ] && case "$out" in *"uid 0 may not use a settings helper started for uid $me"*) ;; *) false ;; esac \
    || fail "root, a caller who is not the helper's uid, was not refused by name: $out"
  echo "ok: 1. root — the one caller socket permissions do not stop — is refused by the peer check, by name"
else
  echo "note: no passwordless sudo here, so the peer check is not tested against a second uid"
fi
serve --uid "$me" --admin-group "abyss-no-such-group"
ctlrun check energy --powerd on
[ "$rc" != 0 ] && case "$out" in *"not an administrator"*) ;; *) false ;; esac \
  || fail "a caller who is not an administrator was not refused: $out"
echo "ok: 1. a caller who is not an administrator is refused, in words"

# ---------------------------------------------------------------- 2. check
serve --uid "$me" --admin-group "$mygroup"
ctlrun check energy --powerd on --ac max --battery adaptive
[ "$rc" = 0 ] || fail "check refused a good plan: $out"
case "$out" in *"$ sysrc -f $work/rc.conf powerd_flags=-a max -b adaptive"*) ;; *) fail "check did not show the command: $out" ;; esac
case "$out" in *"$ service powerd onerestart"*) ;; *) fail "check did not show the restart: $out" ;; esac
ctlrun check energy --powerd on --ac turbo
[ "$rc" != 0 ] && case "$out" in *"powerd has no mode turbo"*) ;; *) false ;; esac || fail "a bad mode was not refused: $out"
[ "$(cat "$work/rc.conf")" = "$original" ] || fail "check wrote rc.conf"
echo "ok: 2. check shows the exact commands, refuses a bad mode by name, and runs nothing"

# ---------------------------------------------------------------- 3. dry run
serve --uid "$me" --admin-group "$mygroup" --dry-run
ctlrun apply energy --powerd on --ac max
[ "$rc" = 0 ] || fail "a dry run failed: $out"
[ "$(printf '%s\n' "$out" | grep -c '^\[')" = 3 ] || fail "a dry run did not report three steps: $out"
[ "$(cat "$work/rc.conf")" = "$original" ] || fail "a dry run wrote rc.conf"
[ ! -e "$work/rc.conf.abyss-staged" ] || fail "a dry run left a staged copy"
grep -q "apply energy for uid $me (dry run)" "$work/journal" || fail "the journal did not record the dry run: $(cat "$work/journal" 2>/dev/null)"
echo "ok: 3. a dry run reports every step, writes nothing, and the journal says so"

# ---------------------------------------------------------------- 4 / 5
serve --uid "$me" --admin-group "$mygroup"
if [ "$freebsd" = 0 ]; then
  ctlrun read energy
  [ "$rc" != 0 ] && case "$out" in *"not FreeBSD"*) ;; *) false ;; esac || fail "Linux did not refuse a read: $out"
  ctlrun apply energy --powerd off
  [ "$rc" != 0 ] && case "$out" in *"not FreeBSD"*) ;; *) false ;; esac || fail "Linux did not refuse an apply: $out"
  [ "$(cat "$work/rc.conf")" = "$original" ] || fail "a refused apply wrote rc.conf"
  echo "ok: 4. on Linux a real read or apply is refused, in words, and nothing is written"
else
  etc_before=$(sha256 -q /etc/rc.conf)
  ctlrun apply energy --powerd off
  [ "$rc" = 0 ] || fail "applying powerd off failed: $out"
  grep -q '^powerd_enable="NO"' "$work/rc.conf" || fail "sysrc did not write powerd_enable: $(cat "$work/rc.conf")"
  grep -q '^hostname="abyss"' "$work/rc.conf" || fail "the rest of rc.conf was not kept: $(cat "$work/rc.conf")"
  [ ! -e "$work/rc.conf.abyss-staged" ] || fail "a staged copy was left behind"
  ctlrun read energy
  [ "$rc" = 0 ] && [ "$out" = "energy: powerd off, ac hiadaptive, battery adaptive" ] \
    || fail "read did not agree with what was applied: $out"
  [ "$(sha256 -q /etc/rc.conf)" = "$etc_before" ] || fail "the machine's own /etc/rc.conf changed"
  grep -q "apply energy for uid $me\$" "$work/journal" || fail "the journal did not record the apply"
  echo "ok: 5. as root on FreeBSD: sysrc wrote the scratch rc.conf whole, read agrees, /etc/rc.conf untouched"
fi

# ---------------------------------------------------------------- 6. network
serve --uid "$me" --admin-group "$mygroup"
ctlrun check network --interface em99 --dhcp
[ "$rc" != 0 ] && case "$out" in *"there is no interface em99 on this machine"*) ;; *) false ;; esac \
  || fail "an interface this machine lacks was not refused: $out"
ctlrun check network --interface em0 --address 10.0.0.300 --netmask 255.255.255.0
[ "$rc" != 0 ] && case "$out" in *"10.0.0.300 is not an IPv4 address"*) ;; *) false ;; esac \
  || fail "a bad address was not refused: $out"
ctlrun check network --interface lo0 --dhcp
[ "$rc" != 0 ] && case "$out" in *"lo0 is not a wired interface's name"*) ;; *) false ;; esac \
  || fail "the loopback was not refused: $out"
if [ "$freebsd" = 0 ]; then
  echo "ok: 6. network: an absent interface, a bad address and the loopback refused, in words (this box has no FreeBSD interface to go further)"
else
  iface=$(ifconfig -l | tr ' ' '\n' | grep -v '^lo' | head -1)
  ctlrun check network --interface "$iface" --address 10.77.0.5 --netmask 255.255.255.0 --router 10.77.0.1 --dns "10.77.0.1 9.9.9.9"
  [ "$rc" = 0 ] || fail "check refused a good plan for $iface: $out"
  case "$out" in *"$ service netif restart $iface"*) ;; *) fail "check did not show the interface restart: $out" ;; esac
  case "$out" in *"name_servers=10.77.0.1 9.9.9.9"*) ;; *) fail "check did not show the name servers: $out" ;; esac

  serve --uid "$me" --admin-group "$mygroup" --dry-run
  ctlrun apply network --interface "$iface" --address 10.77.0.5 --netmask 255.255.255.0 --router 10.77.0.1
  [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^\[')" = 6 ] || fail "a dry run of $iface did not report six steps: $out"
  [ ! -e "$work/resolvconf.conf" ] || fail "a dry run wrote resolvconf.conf"

  serve --uid "$me" --admin-group "$mygroup" --write-only
  ctlrun apply network --interface "$iface" --address 10.77.0.5 --netmask 255.255.255.0 --router 10.77.0.1 --dns "10.77.0.1"
  [ "$rc" = 0 ] || fail "a write-only apply failed: $out"
  grep -q "^ifconfig_$iface=\"inet 10.77.0.5 netmask 255.255.255.0\"" "$work/rc.conf" || fail "rc.conf: $(cat "$work/rc.conf")"
  grep -q '^defaultrouter="10.77.0.1"' "$work/rc.conf" || fail "no defaultrouter: $(cat "$work/rc.conf")"
  grep -q '^name_servers="10.77.0.1"' "$work/resolvconf.conf" || fail "resolvconf.conf: $(cat "$work/resolvconf.conf")"
  [ "$(printf '%s\n' "$out" | grep -c '(skipped)')" = 3 ] || fail "netif, routing and resolvconf were not said to be skipped: $out"
  ctlrun read network --interface "$iface"
  [ "$out" = "network $iface: 10.77.0.5/24 via 10.77.0.1, dns 10.77.0.1" ] || fail "read did not agree: $out"
  ctlrun apply network --interface "$iface" --dhcp
  ctlrun read network --interface "$iface"
  [ "$out" = "network $iface: dhcp" ] || fail "back to DHCP, read says: $out"
  grep -q '^defaultrouter' "$work/rc.conf" && fail "DHCP kept the manual router: $(cat "$work/rc.conf")"
  grep -q '^name_servers' "$work/resolvconf.conf" && fail "DHCP kept the chosen name servers"
  echo "ok: 6. network on $iface: check, a dry run, a write-only apply (both files, three actions skipped and said), read agrees, and back to DHCP"
fi

# ------------------------------------------------------------------ 7. sound
serve --uid "$me" --admin-group "$mygroup"
[ "$freebsd" = 1 ] && { sudo kldload -n snd_dummy 2>/dev/null || true; }
ctlrun check sound --default pcm7
[ "$rc" != 0 ] && case "$out" in *"there is no sound device pcm7 on this machine"*) ;; *) false ;; esac \
  || fail "a device this machine lacks was not refused: $out"
ctlrun check sound --default speakers
[ "$rc" != 0 ] && case "$out" in *"speakers is not a sound device (pcm0, pcm1"*) ;; *) false ;; esac \
  || fail "a name that is no device was not refused: $out"
if [ "$freebsd" = 0 ]; then
  ctlrun read sound
  [ "$rc" != 0 ] && case "$out" in *"not FreeBSD"*) ;; *) false ;; esac || fail "Linux read sound: $out"
  echo "ok: 7. sound: an absent device and a non-device refused in words; a read refused, because this is not FreeBSD"
else
  [ -e /dev/dsp0 ] || fail "no /dev/dsp0 even with snd_dummy loaded"
  dunit=$(sysctl -n hw.snd.default_unit)
  printf '# kernel settings\nkern.coredump=1\n' > "$work/sysctl.conf"; chmod 644 "$work/sysctl.conf"
  ctlrun read sound
  [ "$out" = "sound: default pcm$dunit" ] || fail "with nothing in sysctl.conf, read did not give the kernel's default ($dunit): $out"
  ctlrun check sound --default "pcm$dunit"
  [ "$rc" = 0 ] || fail "check refused pcm$dunit: $out"
  case "$out" in *"(the helper edits the file itself)"*"$ sysctl hw.snd.default_unit=$dunit"*) ;; *) fail "check: $out" ;; esac
  serve --uid "$me" --admin-group "$mygroup" --write-only
  ctlrun apply sound --default "pcm$dunit"
  [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c '(skipped)')" = 1 ] || fail "write-only apply: $out"
  [ "$(cat "$work/sysctl.conf")" = "$(printf '# kernel settings\nkern.coredump=1\nhw.snd.default_unit=%s' "$dunit")" ] \
    || fail "sysctl.conf is not the old one plus the default: $(cat "$work/sysctl.conf")"
  ctlrun read sound
  [ "$out" = "sound: default pcm$dunit" ] || fail "read after apply: $out"
  serve --uid "$me" --admin-group "$mygroup"
  ctlrun apply sound --default "pcm$dunit"
  [ "$rc" = 0 ] || fail "a real apply as root failed: $out"
  case "$out" in *"run sysctl hw.snd.default_unit=$dunit"*"done"*) ;; *) fail "the sysctl step did not run: $out" ;; esac
  case "$out" in *skipped*) fail "a real apply skipped something: $out" ;; esac
  [ "$(sysctl -n hw.snd.default_unit)" = "$dunit" ] || fail "the guest's default moved"
  echo "ok: 7. sound: refusals in words; the kernel's default read; sysctl.conf written whole (write-only), then a real sysctl as root — pcm$dunit, unchanged"
fi

echo "all green (the settings helper admits an administrator, compiles, and writes rc.conf whole or not at all)."
