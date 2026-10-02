#!/bin/sh
# AbyssBSD Swift DE — abyss-jaild, the root half of confinement (PHASE18 P18.2).
#
# The real daemon, as root, in temporary roots and homes; the person asks with
# `abyss-jail`. FreeBSD only (Linux has no jails: skipped, and said so). Needs
# passwordless sudo, and makes a throwaway second account. Claims:
#
#   1. a held jail is the person: their uid and their group only, no other
#      home, no master.passwd or spwd.db, a read-only /usr, a writable private
#      home that is a directory of the host's (not their real home), the plan's
#      HOME and runtime directory, and no address;
#   2. a second person cannot run in the first one's jail, gets their own,
#      and root is not confined;
#   3. letting go of the descriptor removes the jail, every mount and the root;
#   4. a daemon killed while a jail is held adopts it when it comes back, and
#      tears it down when it is let go;
#   5. a daemon killed, and the jail let go while it was dead: the next start
#      finds the mounts left behind and removes them;
#   6. an unknown class is refused; a class file that reaches a home is
#      refused by the plan's checks; a class file root does not own alone is
#      ignored.
#
# Usage: abyss/tests/live-jaild.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
[ -x .build/debug/abyss-jaild ] && [ -x .build/debug/abyss-jail ] || swift build

W=$(mktemp -d /tmp/abyss-jd.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild .build/debug/abyss-jail "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jaild.sock"
me=$(id -un) uid=$(id -u) other=jt18
N="abyss-$uid-app"

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E '^abyss-[0-9]+-' || true); do sudo jail -r "$j" 2>/dev/null || true; done
  for m in $(mount -p | awk '{print $2}' | grep "^$RB" | sort -r); do sudo umount -f "$m" 2>/dev/null || true; done
  pw usershow "$other" > /dev/null 2>&1 && sudo pw userdel "$other" -r 2>/dev/null || true
  sudo rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; tail -6 "$W/jd.log" 2>/dev/null | sed 's/^/  jaild| /'; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
J() { "$W/bin/abyss-jail" --socket "$SOCK" "$@"; }
start() {
  # Without the test's fifo ends: a daemon that inherited one would hold a
  # hold open, and the hold would never let go.
  sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" "$@" >> "$W/jd.log" 2>&1 3>&- 4>&- &
  await "$W/jd.log" 'answering at' "the daemon did not start" "$(( $(count 'answering at' "$W/jd.log") + 1 ))"
}
# sudo and the daemon both match, and one may be gone by the time the other is
# killed: kill quietly, then wait until neither is left.
stop() {
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  i=0; while [ -n "$(daemon)" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  [ -z "$(daemon)" ] || fail "the daemon would not die"
}
mounts() { mount -p | awk '{print $2}' | grep -c "^$RB/" || true; }
# Gone means gone: not even dying (`jls -d`). A jail whose programs are
# unreaped zombies is removed and never freed (HANDOFF §2.123).
gone() {  # gone WHY: the jail, its mounts and its root, all gone, within 5 s
  i=0; while { jls -d -j "$N" > /dev/null 2>&1 || [ "$(mounts)" != 0 ] || [ -d "$RB/$uid/app" ]; } && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  jls -j "$N" > /dev/null 2>&1 && fail "$1: the jail is still there"
  jls -d -j "$N" > /dev/null 2>&1 && fail "$1: the jail is removed but still dying: $(ps -axo pid,jid,stat,comm | awk -v j="$(jls -d -j "$N" jid)" '$2 == j' | tr '\n' '|')"
  [ "$(mounts)" = 0 ] || fail "$1: $(mounts) mount(s) left under the roots"
  [ ! -d "$RB/$uid/app" ] || fail "$1: the root directory is left"
}
hold() { mkfifo "$W/$1"; J hold app < "$W/$1" > "$W/$1.out" 2>&1 & }

pw usershow "$other" > /dev/null 2>&1 || sudo pw useradd "$other" -u 1818 -m -s /bin/sh
start

# ------------------------------------------------------------- 1. the person
hold h1; exec 3>"$W/h1"
await "$W/h1.out" "^held $N " "the hold was not granted: $(cat "$W/h1.out")"
jls -j "$N" > /dev/null 2>&1 || fail "jls does not know $N"
[ "$(jls -j "$N" ip4)" = disable ] || fail "the jail has ip4=$(jls -j "$N" ip4), not disable"
J run app -- sh -c 'id -u; id -G; ls /home; test -e /etc/master.passwd && echo MASTER; test -e /etc/spwd.db && echo SPWD;
  touch /usr/x 2>/dev/null && echo USR-WRITABLE; touch ~/made-inside && echo home-writable; echo "$HOME"; echo "$XDG_RUNTIME_DIR"' \
  > "$W/inside" 2>&1 || fail "run in the jail failed: $(cat "$W/inside")"
expect=$(printf '%s\n%s\n%s\nhome-writable\n/home/%s\n/run/user' "$uid" "$(id -g)" "$me" "$me")
[ "$(cat "$W/inside")" = "$expect" ] || fail "inside the jail: $(tr '\n' '|' < "$W/inside") — expected $(echo "$expect" | tr '\n' '|')"
[ -f "$HB/$me/app/made-inside" ] || fail "the private home is not $HB/$me/app"
[ ! -e "$HOME/made-inside" ] || fail "a file made inside appeared in the real home"
[ "$(stat -f %u "$HB/$me/app/made-inside")" = "$uid" ] || fail "the file made inside is not the person's"
jls -j "$N" > /dev/null 2>&1 || fail "a run while held let the jail go (it was the holder's, not the run's)"
# A test asks a jail yes-or-no questions by exit status: `run` must pass it
# through (a run that always said 0 made every "must fail" check vacuous).
st=0; J run app -- sh -c 'exit 7' || st=$?
[ "$st" = 7 ] || fail "run reported exit status $st for a program that exited 7"
st=0; J run app -- sh -c 'kill -9 $$' || st=$?
[ "$st" = 137 ] || fail "run reported $st for a program killed by signal 9 (expected 137)"
echo "ok: 1. the jail is the person (uid $uid, own group only), no secrets, /usr read-only, a private home, no address; run passes exit statuses through"

# ------------------------------------------------------- 2. another person
if sudo -u "$other" "$W/bin/abyss-jail" --socket "$SOCK" spawn-by-name "$N" -- true > "$W/other" 2>&1; then
  fail "$other ran a program in $me's jail"
fi
grep -q "is not yours" "$W/other" || fail "$other's spawn was refused for the wrong reason: $(cat "$W/other")"
sudo -u "$other" "$W/bin/abyss-jail" --socket "$SOCK" run app -- id -u > "$W/other2" 2>&1 || fail "$other could not run in their own: $(cat "$W/other2")"
[ "$(cat "$W/other2")" = 1818 ] || fail "$other's own jail ran as $(cat "$W/other2")"
grep -q 'jaild: abyss-1818-app is jail' "$W/jd.log" || fail "$other did not get a jail of their own"
if sudo "$W/bin/abyss-jail" --socket "$SOCK" run app -- true > "$W/root" 2>&1; then fail "root was given a jail"; fi
grep -q "root is not confined" "$W/root" || fail "root was refused for the wrong reason: $(cat "$W/root")"
echo "ok: 2. $other cannot run in $me's jail and gets their own; root is not confined"

# ------------------------------------------------------------- 3. let go
exec 3>&-
await "$W/h1.out" "^released" "the hold did not let go"
gone "after letting go"
await "$W/jd.log" "jaild: $N removed (its owner let go)" "the daemon did not say it removed $N"
echo "ok: 3. letting go removed the jail, its mounts and its root"

# ------------------------------------------- 4. killed, back, adopts, removes
hold h2; exec 4>"$W/h2"
await "$W/h2.out" "^held $N " "the second hold was not granted"
stop
start
await "$W/jd.log" "jaild: adopted $N, still running" "the restarted daemon did not adopt $N"
exec 4>&-
gone "after letting go of an adopted jail"
echo "ok: 4. a restarted daemon adopted the held jail, and removed it when let go"

# --------------------------------------- 5. killed, let go while dead, swept
rm -f "$W/h3"; hold h3; exec 4>"$W/h3"
await "$W/h3.out" "^held $N " "the third hold was not granted: $(cat "$W/h3.out" 2>/dev/null)"
stop
exec 4>&-
await "$W/h3.out" "^released" "the third hold did not let go"
i=0; while jls -j "$N" > /dev/null 2>&1 && [ $i -lt 50 ]; do i=$((i + 1)); sleep 0.05; done
[ "$(mounts)" != 0 ] || fail "nothing was left behind to sweep (the test proves nothing)"
start
await "$W/jd.log" "jaild: $N removed (left by a previous run)" "the daemon did not sweep what a dead one left"
gone "after the sweep"
echo "ok: 5. what a dead daemon left behind was swept on the next start"

# ------------------------------------------------------------ 6. refusals
if J run nonesuch -- true > "$W/r1" 2>&1; then fail "an unknown class was granted"; fi
grep -q "no class 'nonesuch'" "$W/r1" || fail "an unknown class was refused for the wrong reason: $(cat "$W/r1")"
stop
printf '[app]\nsystem = /bin /lib /libexec /usr /home\n' | sudo tee "$W/classes.ini" > /dev/null
sudo chown root:wheel "$W/classes.ini"; sudo chmod 644 "$W/classes.ini"
start --classes "$W/classes.ini"
if J run app -- true > "$W/r2" 2>&1; then fail "a class that mounts /home was granted"; fi
grep -q "reaches the person's own home" "$W/r2" || fail "a class mounting /home was refused for the wrong reason: $(cat "$W/r2")"
[ "$(mounts)" = 0 ] || fail "a refused plan left mounts behind"
stop
sudo chown "$uid" "$W/classes.ini"
start --classes "$W/classes.ini"
await "$W/jd.log" "classes.ini is not root's alone" "a class file the person owns was not ignored"
J run app -- true > "$W/r3" 2>&1 || fail "with the file ignored, the shipped app class was refused: $(cat "$W/r3")"
echo "ok: 6. unknown class refused; a class reaching a home refused by the plan; a non-root class file ignored"
echo "all green (abyss-jaild: a person's jail, theirs alone, and nothing left when they let go)."
