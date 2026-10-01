#!/bin/sh
# AbyssBSD Swift DE — the session's authenticator (PHASE16 P16.1).
#
# Nothing unprivileged can check a password on FreeBSD (PHASE16 §4.2), so
# `abyss-loginwindow` — root — answers one question for whoever asks: *is this
# my password?* Run here as root against the PAM stack the medium ships
# (abyss/etc/pam.d/abyss, installed for the run as a throwaway service), with
# two throwaway accounts, each asking as itself:
#
#   1. an account's own password is accepted;
#   2. another account's password is refused — the caller is who the kernel
#      says, and the request names nobody;
#   3. after two free typos, a third failure makes the next try wait, and
#      during the wait even the right password is refused unasked; after it,
#      accepted;
#   4. one account's wait does not hold up another;
#   5. an account with no password is accepted with anything (`nullok`, as
#      FreeBSD's own `system` stack has it — no password, nothing to check),
#      and the shipped stack has no pam_self, which would let a root session
#      through on anything *whatever* root's password;
#   6. no password appears in anything the daemon wrote;
#   7. power (P16.4a), through the real daemon with stand-in acpiconf and
#      shutdown: an ordinary account may put the machine to sleep and may not
#      restart or shut it down — refused in words, nothing run; an account in
#      wheel may; and no account but root may report the lid or the keys;
#   8. the login window (P16.5a): its account, `_loginwindow`, may ask about a
#      named account's password — right accepted, wrong refused — and may
#      restart; an ordinary account may not ask about another.
#
# On Linux there is no PAM to ask, and the daemon must say so (the positive
# control). Needs root in the guest (passwordless sudo, as the build VM has).
#
# Usage: abyss/tests/live-authenticator.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"

daemon="$root/.build/debug/abyss-loginwindow"
ctl="$root/.build/debug/abyss-loginctl"
[ -x "$daemon" ] && [ -x "$ctl" ] || swift build

fail() { echo "FAIL: $1"; [ -s "${work:-/nonexistent}/daemon.log" ] && sed 's/^/  daemon| /' "$work/daemon.log" | tail -8; exit 1; }

# ------------------------------------------------------------ Linux
if [ "$(uname -s)" != FreeBSD ]; then
  set +e; out=$("$daemon" --socket /nonexistent.sock 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no PAM to ask' \
    || fail "on Linux the authenticator did not refuse in words: rc=$rc $out"
  echo "ok: on $(uname -s) the authenticator refuses, saying there is no PAM to ask"
  echo "all green (Linux half: the refusal)."
  exit 0
fi
sudo -n true 2>/dev/null || { echo "SKIP: no passwordless sudo here — the authenticator needs root"; exit 0; }

work=$(mktemp -d /tmp/abyss-auth.XXXXXX)
chmod 755 "$work"
svc="abyss-test-$$"
ua="abyss16a$$"; ub="abyss16b$$"; uc="abyss16c$$"; uw="abyss16w$$"
pa="correct-horse-$$"; pb="battery-staple-$$"
cleanup() {
  [ -n "${dpid:-}" ] && sudo kill "$dpid" 2>/dev/null || true
  sudo pw userdel "$ua" -r 2>/dev/null || true
  sudo pw userdel "$ub" -r 2>/dev/null || true
  sudo pw userdel "$uc" -r 2>/dev/null || true
  sudo pw userdel "$uw" -r 2>/dev/null || true
  [ "${made_greeter:-0}" = 1 ] && sudo pw userdel _loginwindow 2>/dev/null || true
  sudo rm -f "/etc/pam.d/$svc" 2>/dev/null || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

sudo install -m 644 "$root/abyss/etc/pam.d/abyss" "/etc/pam.d/$svc"
echo "$pa" | sudo pw useradd "$ua" -m -h 0 >/dev/null || fail "could not make $ua"
echo "$pb" | sudo pw useradd "$ub" -m -h 0 >/dev/null || fail "could not make $ub"
sudo pw useradd "$uc" -m -w none >/dev/null || fail "could not make $uc"
sudo pw useradd "$uw" -m -w none -G wheel >/dev/null || fail "could not make $uw"
# The login window's account, as the installer will make it (P16.5b); made
# here only if this machine has none, and then removed again.
made_greeter=0
if ! id _loginwindow > /dev/null 2>&1; then
  sudo pw useradd _loginwindow -u 1099 -d /nonexistent -s /usr/sbin/nologin -c "Login Window" -w no > /dev/null \
    || fail "could not make _loginwindow"
  made_greeter=1
fi
# Stand-ins for the machine's own commands: they record, as root, what they
# were asked. Nothing here suspends or reboots the build VM.
for c in acpiconf shutdown; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/power.log"\n' "$c" "$work" > "$work/$c"
  chmod 755 "$work/$c"
done
: > "$work/power.log"; chmod 666 "$work/power.log"
# The client runs as each account: a copy it can read and run.
cp "$ctl" "$work/abyss-loginctl"; chmod 755 "$work/abyss-loginctl"

sock="$work/auth.sock"
sudo sh -c "'$daemon' --socket '$sock' --pam-service '$svc' --acpiconf '$work/acpiconf' --shutdown '$work/shutdown' > '$work/daemon.log' 2>&1 & echo \$! > '$work/pid'"
i=0; while [ ! -S "$sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$sock" ] || fail "the authenticator never bound its socket"
dpid=$(cat "$work/pid")

ask() {  # ask USER PASSWORD -> the client's one-line answer
  if [ "$1" = root ]; then printf '%s\n' "$2" | sudo "$work/abyss-loginctl" --socket "$sock" verify || true
  else printf '%s\n' "$2" | sudo -u "$1" "$work/abyss-loginctl" --socket "$sock" verify || true
  fi
}

# ------------------------------------------------------------ 1. own
[ "$(ask "$ua" "$pa")" = accepted ] || fail "$ua's own password was not accepted: $(ask "$ua" "$pa")"
echo "ok: 1. an account's own password is accepted"

# ------------------------------------------------------------ 2. not another's
[ "$(ask "$ua" "$pb")" = refused ] || fail "$ua, offering $ub's password, was not refused"
echo "ok: 2. another account's password is refused — the uid decides whose is checked"

# ------------------------------------------------------------ 3. the wait
ask "$ua" "typo-1" > /dev/null                      # with the one in 2, the second typo
got=$(ask "$ua" "typo-2")                           # the third failure: from now on, a wait
[ "$got" = refused ] || fail "the third failure answered '$got'"
got=$(ask "$ua" "$pa")
case "$got" in
  "wait "*) ms=${got#wait } ;;
  *) fail "right after a third failure, even the right password should wait; got '$got'" ;;
esac
grep -q "asked again too soon" "$work/daemon.log" || fail "the daemon did not log that it refused unasked"
sleep $(( (ms + 999) / 1000 ))
[ "$(ask "$ua" "$pa")" = accepted ] || fail "after the wait, the right password was not accepted"
echo "ok: 3. two typos free, then a wait (${ms} ms) during which even the right password was refused unasked; after it, accepted"

# ------------------------------------------------------------ 4. independent
for k in 1 2 3; do ask "$ua" "wrong-$k" > /dev/null; done
[ "$(ask "$ub" "$pb")" = accepted ] || fail "$ub was held up by $ua's failures"
echo "ok: 4. one account's wait does not hold up another"

# ------------------------------------------------------------ 5. nullok, no pam_self
# (The build VM's own root has no password, so root is accepted with anything
# here — the same nullok rule, not a hole: found writing this test, §2.100.)
[ "$(ask "$uc" "anything-$$")" = accepted ] \
  || fail "an account with no password was not accepted (nullok, as FreeBSD's system stack)"
grep -v '^#' "$root/abyss/etc/pam.d/abyss" | grep -q 'pam_self' && fail "the shipped stack names pam_self"
grep -v '^#' "$root/abyss/etc/pam.d/abyss" | grep -q 'include' && fail "the shipped stack includes another (login's begins with pam_self)"
echo "ok: 5. an account with no password is accepted with anything (nullok); the stack has no pam_self and includes nothing"

# ------------------------------------------------------------ 6. never written
for p in "$pa" "$pb" "typo-1" "typo-2"; do
  grep -qF -- "$p" "$work/daemon.log" && fail "the daemon wrote a password to its log: $p"
done
grep -q "($ua): accepted" "$work/daemon.log" || fail "the log does not say who was accepted"
echo "ok: 6. no password in anything the daemon wrote ($(grep -c 'loginwindow: uid' "$work/daemon.log") answers logged)"

# ------------------------------------------------------------ 7. power
power() { sudo -u "$1" "$work/abyss-loginctl" --socket "$sock" power "$2" || true; }
[ "$(power "$ua" restart)" = "refused: only an administrator can restart this computer" ] \
  || fail "an ordinary account's restart: $(power "$ua" restart)"
[ "$(power "$ua" shut-down)" = "refused: only an administrator can shut down this computer" ] \
  || fail "an ordinary account's shut down: $(power "$ua" shut-down)"
for k in lid sleep-key power-key; do
  [ "$(power "$uw" "$k")" = "refused: only the system reports the machine's buttons" ] \
    || fail "an account, even in wheel, reported the $k: $(power "$uw" "$k")"
done
[ "$(power "$ua" sleep)" = ok ] || fail "an ordinary account could not put the machine to sleep"
i=0; while ! grep -q '^acpiconf -s 3$' "$work/power.log" && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
grep -q '^acpiconf -s 3$' "$work/power.log" || fail "sleep did not run acpiconf -s 3: $(cat "$work/power.log")"
grep -q '^shutdown' "$work/power.log" && fail "shutdown ran for an ordinary account"
[ "$(power "$uw" restart)" = ok ] || fail "an account in wheel could not restart: $(power "$uw" restart)"
i=0; while ! grep -q '^shutdown -r now$' "$work/power.log" && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
grep -q '^shutdown -r now$' "$work/power.log" || fail "restart did not run shutdown -r now: $(cat "$work/power.log")"
echo "ok: 7. power: an ordinary account may sleep the machine, not restart or shut it down (refused in words); wheel may restart; nobody but root reports the lid or the keys"

# ------------------------------------------------------------ 8. the login window
lw() { printf '%s\n' "$3" | sudo -u "$1" "$work/abyss-loginctl" --socket "$sock" login "$2" || true; }
grep -q "the login window's account is _loginwindow" "$work/daemon.log" || fail "the daemon did not find _loginwindow"
[ "$(lw _loginwindow "$ub" "$pb")" = accepted ] || fail "the login window, with $ub's password: $(lw _loginwindow "$ub" "$pb")"
[ "$(lw _loginwindow "$ub" "not-it")" = refused ] || fail "the login window, with a wrong password, was not refused"
case "$(lw "$ua" "$ub" "$pb")" in
  "error: only the login window may ask about another account") ;;
  *) fail "an ordinary account asked about another: $(lw "$ua" "$ub" "$pb")" ;;
esac
n=$(grep -c '^shutdown -r now$' "$work/power.log" || true)
[ "$(power _loginwindow restart)" = ok ] || fail "the login window could not restart: $(power _loginwindow restart)"
i=0; while [ "$(grep -c '^shutdown -r now$' "$work/power.log" || true)" -le "$n" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(grep -c '^shutdown -r now$' "$work/power.log" || true)" -gt "$n" ] || fail "the login window's restart ran nothing"
for p in "$pb" not-it; do grep -qF -- "$p" "$work/daemon.log" && fail "the daemon logged a login window password"; done
echo "ok: 8. the login window may ask about a named account (right accepted, wrong refused) and may restart; nobody else may ask"

echo "all green (the authenticator answers each person about themselves, slowly when they guess, and writes no password down)."
