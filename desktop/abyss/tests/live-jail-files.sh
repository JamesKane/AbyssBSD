#!/bin/sh
# AbyssBSD Swift DE — files into a jail through the Open panel (PHASE18 P18.4).
#
# A jail has no path to the person's files. One gets in when they choose it:
# the jailed application asks org.freedesktop.portal.FileChooser on the jail's
# own bus, abyss-portal runs the picker (a stand-in here that "chooses" a named
# file) and opens what was chosen, and the jail's abyss-dbus hands that
# descriptor to abyss-jaild, which mounts that one file into the jail and
# says where. The descriptor is the proof: a grant reaches nothing the person
# could not open, and is writable only if the descriptor is.
#
# Real processes throughout: jaild as root, ADE's D-Bus bridge for the jail
# (BACKLOG D.1 — a bridge, never a bus) with its services socket outside the
# jail, abyss-portal, abyss-dbus --jail, and a GLib (GDBus) caller running
# inside the jail. FreeBSD only; needs passwordless sudo. Claims:
#
#   1. OpenFile from inside: the Response names the file at its place in the
#      jail, which reads as the real one, alone in its directory, and
#      read-only;
#   2. SaveFile from inside: a new file, granted writable, and what the jail
#      writes is in the real file;
#   3. the grants are listed, and a revoked one is gone from the jail while
#      the real file is untouched;
#   4. forged grants are refused: a descriptor of another file, a path through
#      a link, a directory, and another person's grant into this jail;
#   5. letting go of the jail removes the grants with it.
#
# Usage: abyss/tests/live-jail-files.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for t in gdbus pkg-config; do command -v $t > /dev/null || { echo "FAIL: $t not installed"; exit 1; }; done
for b in abyss-jaild abyss-jail abyss-portal abyss-dbus; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-jf.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild .build/debug/abyss-jail "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
me=$(id -un) uid=$(id -u) other=jt18
N="abyss-$uid-app"
export XDG_RUNTIME_DIR="$W/xdg"; mkdir -m 700 "$XDG_RUNTIME_DIR"
docs=$(mktemp -d /tmp/abyss-jfd.XXXXXX)
printf 'the contents\n' > "$docs/doc.txt"; printf 'not chosen\n' > "$docs/secret.txt"

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${bus:-} ${pt:-} ${br:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E '^abyss-[0-9]+-' || true); do sudo jail -r "$j" 2>/dev/null || true; done
  for m in $(mount -p | awk '{print $2}' | grep "^$RB" | sort -r); do sudo umount -f "$m" 2>/dev/null || true; done
  pw usershow "$other" > /dev/null 2>&1 && sudo pw userdel "$other" -r 2>/dev/null || true
  sudo rm -rf "$W" "$docs"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in jd.log bus.log br.log call.log; do tail -4 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
J() { "$W/bin/abyss-jail" --socket "$SOCK" "$@"; }
inside() { J run app -- "$@" 3>&-; }
mounts() { mount -p | awk '{print $2}' | grep -c "^$RB/" || true; }

pw usershow "$other" > /dev/null 2>&1 || sudo pw useradd "$other" -u 1818 -m -s /bin/sh
sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$W/jd.log" 2>&1 3>&- &
await "$W/jd.log" 'answering at' "the daemon did not start"
mkfifo "$W/h"; J hold app < "$W/h" > "$W/h.out" 2>&1 & exec 3>"$W/h"
await "$W/h.out" "^held $N " "no jail"
jroot=$(sed -n 's/.* root=\([^ ]*\).*/\1/p' "$W/h.out")
runtime="$jroot/run/user"

# The jail's D-Bus bridge: the jail's applications on the socket inside it,
# the jail's portal on the services socket outside it — where nothing jailed
# can reach. No application reaches another through it (PRODUCT §5.6).
.build/debug/abyss-dbus --endpoint --listen "$runtime/bus" --services "$W/jail-services" > "$W/bus.log" 2>&1 3>&- & bus=$!
await "$W/bus.log" '^ready' "the jail's bridge did not start"
# The stand-in picker "chooses" whatever $W/choose names.
printf '#!/bin/sh\ncat "%s" > "$ABYSS_FINDER_PICK"\n' "$W/choose" > "$W/pick.sh"; chmod 755 "$W/pick.sh"
ABYSS_PICKER="$W/pick.sh" .build/debug/abyss-portal > "$W/pt.log" 2>&1 3>&- & pt=$!
.build/debug/abyss-dbus --bus "unix:path=$W/jail-services" --jail "$N" --jaild "$SOCK" > "$W/br.log" 2>&1 3>&- & br=$!
await "$W/br.log" '^ready' "the jail's portal did not start"

# Inside: a GLib caller, built into the jail's own home (it may exec there;
# setuid it may not). It hears its own Response — the bridge lets nobody watch.
cc abyss/tests/portalcall.c $(pkg-config --cflags --libs gio-2.0) -o "$W/portalcall" || fail "cannot build the GLib caller"
cp "$W/portalcall" "$HB/$(id -un)/app/portalcall"
ask() {  # ask METHOD TOKEN [NAME]: call FileChooser from inside, as GLib; its Response in $W/call.log
  inside "/home/$(id -un)/portalcall" "$1" "$2" "${3:--}" > "$W/call.log" 2>&1 || fail "no Response reached the jail for $1: $(cat "$W/call.log")"
  grep -q '^response 0$' "$W/call.log" || fail "$1 from the jail did not succeed: $(cat "$W/call.log")"
}

# --------------------------------------------------------- 1. OpenFile
echo "$docs/doc.txt" > "$W/choose"
ask OpenFile t1
grep -q '^uri file:///run/granted/1/doc.txt$' "$W/call.log" || fail "the Response does not name /run/granted/1/doc.txt: $(tr '\n' ' ' < "$W/call.log")"
[ "$(inside cat /run/granted/1/doc.txt)" = "the contents" ] || fail "the granted file does not read as the real one"
[ "$(inside ls /run/granted/1)" = doc.txt ] || fail "the grant's directory holds more than the file"
inside sh -c 'ls /run/granted; ls /run/granted/*' | grep -q secret && fail "the file beside the chosen one is visible"
inside sh -c 'echo x >> /run/granted/1/doc.txt' 2> /dev/null && fail "a file opened for reading was granted writable"
[ "$(cat "$docs/doc.txt")" = "the contents" ] || fail "the real file changed"
echo "ok: 1. OpenFile from the jail: the Response names /run/granted/1/doc.txt, the real file, alone, read-only"

# --------------------------------------------------------- 2. SaveFile
echo "$docs/saved.txt" > "$W/choose"
ask SaveFile t2 saved.txt
grep -q '^uri file:///run/granted/2/saved.txt$' "$W/call.log" || fail "the SaveFile Response does not name /run/granted/2/saved.txt: $(tr '\n' ' ' < "$W/call.log")"
inside sh -c 'echo "written in the jail" > /run/granted/2/saved.txt' || fail "the jail could not write the file it was given to save"
[ "$(cat "$docs/saved.txt")" = "written in the jail" ] || fail "what the jail wrote is not in the real file: '$(cat "$docs/saved.txt")'"
echo "ok: 2. SaveFile from the jail: granted writable, and the jail's write is in the real file"

# ---------------------------------------------------------- 3. list, revoke
J grants "$N" > "$W/grants"
grep -q "^1	ro	/run/granted/1/doc.txt	$docs/doc.txt$" "$W/grants" || fail "grant 1 is not listed as read-only: $(cat "$W/grants")"
grep -q "^2	rw	/run/granted/2/saved.txt	$docs/saved.txt$" "$W/grants" || fail "grant 2 is not listed as read-write: $(cat "$W/grants")"
J revoke "$N" 1 > /dev/null || fail "revoke failed"
inside test -e /run/granted/1/doc.txt && fail "a revoked file is still in the jail"
[ "$(cat "$docs/doc.txt")" = "the contents" ] || fail "revoking changed the real file"
[ "$(J grants "$N" | wc -l | tr -d ' ')" = 1 ] || fail "the revoked grant is still listed"
echo "ok: 3. the grants are listed ro and rw; a revoked one left the jail, and the real file is untouched"

# ------------------------------------------------------------ 4. forgeries
J grant "$N" /etc/passwd --fd-of "$docs/secret.txt" > "$W/f1" 2>&1 && fail "a grant proven by another file's descriptor was made"
grep -q "is not the file the descriptor is" "$W/f1" || fail "forgery 1 refused for the wrong reason: $(cat "$W/f1")"
ln -s "$docs/secret.txt" "$docs/link.txt"
J grant "$N" "$docs/link.txt" > "$W/f2" 2>&1 && fail "a grant through a link was made"
grep -q "is not a resolved path" "$W/f2" || fail "forgery 2 refused for the wrong reason: $(cat "$W/f2")"
J grant "$N" "$docs" > "$W/f3" 2>&1 && fail "a directory was granted"
grep -q "not a regular file" "$W/f3" || fail "forgery 3 refused for the wrong reason: $(cat "$W/f3")"
chmod 755 "$docs"; chmod 644 "$docs/secret.txt"
sudo -u "$other" "$W/bin/abyss-jail" --socket "$SOCK" grant "$N" "$docs/secret.txt" > "$W/f4" 2>&1 && fail "$other granted a file into $me's jail"
grep -q "is not yours" "$W/f4" || fail "forgery 4 refused for the wrong reason: $(cat "$W/f4")"
inside test -e /run/granted/3 && fail "a refused grant left something in the jail"
echo "ok: 4. refused: another file's descriptor, a link, a directory, another person's grant"

# --------------------------------------------------------------- 5. let go
exec 3>&-
i=0; while { jls -j "$N" > /dev/null 2>&1 || [ "$(mounts)" != 0 ]; } && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
[ "$(mounts)" = 0 ] || fail "$(mounts) mount(s) left after letting go (the grants?)"
[ "$(cat "$docs/saved.txt")" = "written in the jail" ] || fail "letting go changed a granted file"
echo "ok: 5. letting go of the jail took its grants with it; the real files stay"
echo "all green (a file reaches a jail when it is chosen, that file alone, and only as far as it was opened)."
