#!/bin/sh
# AbyssBSD Swift DE — accounts, through the settings helper (PHASE16 P16.6a).
#
# `abyss-settings` (root) commanded by `abyss-settingsctl accounts` (this
# user), as the Accounts pane commands it. On FreeBSD, as root, against a
# **scratch root** (`pw -R`: copies of the password and group files) and a
# scratch rc.conf — the machine's own accounts are read, never changed. Claims:
#
#   1. `check` shows what a new account compiles to — and neither the
#      password nor its hash is in it;
#   2. (FreeBSD) a standard user is made: a person's uid, audio and video,
#      not wheel, a home of their own, the password stored hashed;
#   3. the same name again is refused; an administrator is made in wheel;
#   4. automatic login on writes rc.conf's abyss_desktop lines in place of
#      the login window's; an account that does not exist is refused; off
#      puts the login window back;
#   5. a user deleted keeps their home folder unless asked; with
#      --remove-home it goes; the administrator's own account, and root,
#      are refused;
#   6. nothing anybody typed or hashed is in the journal or the helper's log,
#      and the machine's /etc/master.passwd is unchanged;
#   (Linux) an apply is refused in words, and nothing is written.
#
# Usage: abyss/tests/live-accounts.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"

helper="$root/.build/debug/abyss-settings"
ctl="$root/.build/debug/abyss-settingsctl"
[ -x "$helper" ] && [ -x "$ctl" ] || swift build

work=$(mktemp -d /tmp/abyss-accounts.XXXXXX)
chmod 755 "$work"
cleanup() {
  [ -n "${svc_pid:-}" ] && { $sudo kill "$svc_pid" 2>/dev/null || true; }
  $sudo rm -rf "$work" 2>/dev/null || rm -rf "$work" || true
}
fail() { echo "FAIL: $1"; [ -s "$work/svc.err" ] && tail -5 "$work/svc.err" | sed 's/^/  helper| /'; exit 1; }
trap cleanup EXIT INT TERM HUP

freebsd=0; [ "$(uname -s)" = FreeBSD ] && freebsd=1
sudo=""
if [ "$freebsd" = 1 ]; then
  sudo -n true 2>/dev/null || fail "on FreeBSD this test runs the helper as root, and needs passwordless sudo"
  sudo=sudo
fi
rundir="$work/run"; mkdir -p "$rundir"; chmod 700 "$rundir"
export ABYSS_RUNTIME_DIR="$rundir"
printf 'hostname="abyss"\nabyss_loginwindow_flags="--greeter"\n' > "$work/rc.conf"; chmod 644 "$work/rc.conf"

# The scratch root: the machine's own password and group files, copied.
pwroot="$work/root"
mkdir -p "$pwroot/etc" "$pwroot/home" "$pwroot/usr/share/skel"
if [ "$freebsd" = 1 ]; then
  sudo cp /etc/master.passwd /etc/group "$pwroot/etc/"
  sudo pwd_mkdb -p -d "$pwroot/etc" "$pwroot/etc/master.passwd"
  before=$(sudo md5 -q /etc/master.passwd)
fi

$sudo env ABYSS_RUNTIME_DIR="$rundir" "$helper" --uid "$(id -u)" --admin-group "$(id -gn)" --rc-conf "$work/rc.conf" --pw-root "$pwroot" \
    --journal "$work/journal" 2> "$work/svc.err" &
svc_pid=$!
i=0; while [ ! -S "$rundir/settings.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/settings.sock" ] || fail "the helper never came up"
ctlrun() { rc=0; out=$("$ctl" "$@" 2>&1) || rc=$?; }
pa="ada-secret-$$"; pb="bob-secret-$$"
ua="ada$$"; ub="bob$$"
ua=$(echo "$ua" | cut -c1-16); ub=$(echo "$ub" | cut -c1-16)

# ------------------------------------------------------------ 1. check
rc=0; out=$(printf '%s\n' "$pa" | "$ctl" check accounts --add "$ua" --full-name "Ada Test" 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "check: $out"
echo "$out" | grep -q "create the account $ua" || fail "check did not say what it would do: $out"
echo "$out" | grep -qF -- "$pa" && fail "check showed the password"
echo "$out" | grep -q '\$6\$' && fail "check showed the hash: $out"
echo "ok: 1. check: \"create the account $ua\" — no password, no hash"

if [ "$freebsd" = 0 ]; then
  rc=0; out=$(printf '%s\n' "$pa" | "$ctl" apply accounts --add "$ua" 2>&1) || rc=$?
  [ "$rc" != 0 ] && echo "$out" | grep -q "not FreeBSD" || fail "on Linux, apply was not refused in words: $out"
  [ ! -e "$pwroot/etc/master.passwd" ] || fail "something was written"
  echo "ok: on $(uname -s), apply is refused, in words, and nothing is written"
  echo "all green (Linux half: check, and the refusal)."
  exit 0
fi

show() { sudo pw -R "$pwroot" usershow -n "$1" 2>/dev/null || true; }
groups_of() { sudo pw -R "$pwroot" groupshow -a 2>/dev/null | awk -F: -v u="$1" '{ n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) print $1 }' | sort | tr '\n' ' '; }

# ------------------------------------------------------------ 2. a standard user
rc=0; out=$(printf '%s\n' "$pa" | "$ctl" apply accounts --add "$ua" --full-name "Ada Test" 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "adding $ua: $out"
line=$(show "$ua"); [ -n "$line" ] || fail "$ua was not made"
uid=$(echo "$line" | cut -d: -f3)
[ "$uid" -ge 1000 ] || fail "$ua has uid $uid"
[ "$(echo "$line" | cut -d: -f8)" = "Ada Test" ] || fail "the full name: $line"
case "$(echo "$line" | cut -d: -f2)" in '$6$'*) ;; *) fail "the password was not stored hashed: $(echo "$line" | cut -d: -f2 | cut -c1-6)…" ;; esac
g=$(groups_of "$ua"); [ "$g" = "audio video " ] || fail "$ua's groups: '$g'"
[ -d "$pwroot/home/$ua" ] && [ "$(stat -f %u "$pwroot/home/$ua")" = "$uid" ] || fail "$ua has no home of their own"
echo "ok: 2. $ua made: uid $uid, audio and video, a home of their own, the password hashed (\$6\$)"

# ------------------------------------------------------------ 3. again; an administrator
rc=0; out=$(printf '%s\n' "$pa" | "$ctl" apply accounts --add "$ua" 2>&1) || rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "there is already an account $ua" || fail "the same name again: $out"
rc=0; out=$(printf '%s\n' "$pb" | "$ctl" apply accounts --add "$ub" --admin 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "adding $ub: $out"
g=$(groups_of "$ub")
case "$g" in *wheel*) ;; *) fail "$ub, an administrator, is not in wheel: '$g'" ;; esac
case "$g" in *operator*) ;; *) fail "$ub, an administrator, is not in operator: '$g'" ;; esac
echo "ok: 3. the same name again refused; $ub made an administrator ($g)"

# ------------------------------------------------------------ 4. automatic login
ctlrun apply accounts --autologin "$ua"
[ "$rc" = 0 ] || fail "automatic login: $out"
grep -q "^abyss_desktop_enable=\"YES\"" "$work/rc.conf" && grep -q "^abyss_desktop_user=\"$ua\"" "$work/rc.conf" \
  || fail "rc.conf after automatic login: $(cat "$work/rc.conf")"
grep -q abyss_loginwindow_flags "$work/rc.conf" && fail "the login window was left on as well"
ctlrun apply accounts --autologin "nosuch$$"
[ "$rc" != 0 ] && echo "$out" | grep -q "there is no account" || fail "automatic login for nobody: $out"
ctlrun apply accounts --no-autologin
grep -q '^abyss_loginwindow_flags="--greeter"' "$work/rc.conf" && ! grep -q abyss_desktop "$work/rc.conf" \
  || fail "rc.conf after turning automatic login off: $(cat "$work/rc.conf")"
echo "ok: 4. automatic login as $ua in place of the login window; nobody refused; off, the login window again"

# ------------------------------------------------------------ 5. delete
ctlrun apply accounts --delete "$ua"
[ "$rc" = 0 ] || fail "deleting $ua: $out"
[ -z "$(show "$ua")" ] || fail "$ua is still there"
[ -d "$pwroot/home/$ua" ] || fail "$ua's home folder went, unasked"
ctlrun apply accounts --delete "$ub" --remove-home
[ "$rc" = 0 ] && [ ! -d "$pwroot/home/$ub" ] || fail "deleting $ub with its home: $out"
ctlrun apply accounts --delete "$(id -un)"
[ "$rc" != 0 ] && echo "$out" | grep -q "the account you are using" || fail "deleting oneself: $out"
ctlrun apply accounts --delete root
[ "$rc" != 0 ] || fail "root was deleted"
echo "ok: 5. $ua deleted, home kept; $ub deleted with its home; oneself and root refused"

# ------------------------------------------------------------ 6. nothing written down
for f in "$work/journal" "$work/svc.err"; do
  for s in "$pa" "$pb" '$6$'; do sudo grep -qF -- "$s" "$f" && fail "$f contains a password or a hash"; done
done
[ "$(sudo md5 -q /etc/master.passwd)" = "$before" ] || fail "the machine's own master.passwd changed"
echo "ok: 6. no password or hash in the journal or the log; the machine's accounts untouched"
echo "all green (accounts are made, given their groups and homes, logged in automatically, and deleted — by an administrator, through the helper)."
