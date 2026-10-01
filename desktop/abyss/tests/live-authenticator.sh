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
#      restart; an ordinary account may not ask about another;
#   9. sessions (P16.5b), through a second daemon with --greeter and a
#      stand-in session that records who it is: the login window runs as
#      `_loginwindow`; a login starts the person's session **as them** —
#      their uid, not in wheel, in a runtime directory that is theirs and
#      0700 — and its end brings the login window back, each on its own VT
#      (the console's switch a stand-in that records: VT 9, then 10);
#  10. fast user switching's refusals (P16.6b), as the real uids: a session
#      with no agent to lock it cannot switch away, and nobody but the session
#      in front may switch.
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
  [ -n "${dpid2:-}" ] && sudo kill "$dpid2" 2>/dev/null || true
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

# ------------------------------------------------------------ 9. sessions, as root
cat > "$work/session" <<SESSION
#!/bin/sh
echo "\$ABYSS_SESSION_MODE \$(id -un) uid=\$(id -u) groups=\$(id -Gn | tr ' ' ,) run=\$ABYSS_RUNTIME_DIR owner=\$(ls -ld "\$ABYSS_RUNTIME_DIR" | awk '{print \$3}') mode=\$(ls -ld "\$ABYSS_RUNTIME_DIR" | cut -c1-10) home=\$(pwd)" >> "$work/record"
while [ ! -e "$work/end.\$(id -un)" ]; do sleep 0.1; done
rm -f "$work/end.\$(id -un)"
SESSION
chmod 755 "$work/session"; : > "$work/record"; chmod 666 "$work/record"; chmod 777 "$work"
printf '#!/bin/sh\necho "$1" >> "%s/vt.log"\n' "$work" > "$work/vt"; chmod 755 "$work/vt"; : > "$work/vt.log"; chmod 666 "$work/vt.log"
mkdir -p "$work/run"
sock2="$work/auth2.sock"
sudo sh -c "'$daemon' --socket '$sock2' --pam-service '$svc' --greeter --session-command '$work/session' --vt-command '$work/vt' \
  --session-log-dir '$work' --runtime-root '$work/run' > '$work/daemon2.log' 2>&1 & echo \$! > '$work/pid2'"
i=0; while [ ! -S "$sock2" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
dpid2=$(cat "$work/pid2")
rec() { i=0; while [ "$(grep -c "^$1" "$work/record" || true)" -lt "$2" ] && [ $i -lt 80 ]; do sleep 0.1; i=$((i + 1)); done
        grep "^$1" "$work/record" | sed -n "$2p"; }
g=$(rec "greeter _loginwindow " 1)
[ -n "$g" ] || fail "the login window's session never ran: $(cat "$work/daemon2.log")"
case "$g" in *"uid=$(id -u _loginwindow) "*"run=$work/run/abyss-_loginwindow owner=_loginwindow mode=drwx------"*) ;;
  *) fail "the login window's session: $g" ;; esac
[ "$(printf '%s\n' "$pa" | sudo -u _loginwindow "$work/abyss-loginctl" --socket "$sock2" login "$ua")" = accepted ] \
  || fail "the login window could not log $ua in"
d=$(rec "desktop $ua " 1)
[ -n "$d" ] || fail "$ua's session never ran: $(tail -3 "$work/daemon2.log")"
case "$d" in *"uid=$(id -u "$ua") "*"run=$work/run/abyss-$ua owner=$ua mode=drwx------ home=$(getent passwd "$ua" | cut -d: -f6)"*) ;;
  *) fail "$ua's session: $d" ;; esac
case "$d" in *wheel*) fail "$ua's session has wheel: $d" ;; esac
grep -q "ending the login window — $ua logged in" "$work/daemon2.log" || fail "the login window was not ended first"
sudo touch "$work/end.$ua"
g2=$(rec "greeter _loginwindow " 2)
[ -n "$g2" ] || fail "$ua's session ended and the login window did not come back"
echo "ok: 9. sessions: the login window ran as _loginwindow; $ua's session as $ua (uid $(id -u "$ua"), its own 0700 runtime directory, its home, no wheel); its end brought the window back"
[ "$(tr '\n' ' ' < "$work/vt.log")" = "9 10 9 " ] || fail "the VT switches: $(tr '\n' ' ' < "$work/vt.log")"

# ------------------------------------------------------------ 10. switching's refusals
[ "$(printf '%s\n' "$pb" | sudo -u _loginwindow "$work/abyss-loginctl" --socket "$sock2" login "$ub")" = accepted ] \
  || fail "the login window could not log $ub in"
[ -n "$(rec "desktop $ub " 1)" ] || fail "$ub's session never ran"
got=$(sudo -u "$ub" "$work/abyss-loginctl" --socket "$sock2" switch-user || true)
[ "$got" = "refused: not switched: the session has nothing to lock it" ] || fail "$ub, with no agent, switching: $got"
got=$(sudo -u "$ua" "$work/abyss-loginctl" --socket "$sock2" switch-user || true)
[ "$got" = "refused: only the session in front may switch away from itself" ] || fail "$ua, not in front, switching: $got"
[ "$(tr '\n' ' ' < "$work/vt.log")" = "9 10 9 10 " ] || fail "a refused switch moved the VT: $(tr '\n' ' ' < "$work/vt.log")"
echo "ok: 10. switching away is refused for a session nothing can lock, and for anyone not in front — as the real uids"
sudo touch "$work/end.$ub"
sudo touch "$work/end._loginwindow"

echo "all green (the authenticator answers each person about themselves, slowly when they guess, and writes no password down)."
