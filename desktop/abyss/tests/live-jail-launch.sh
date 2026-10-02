#!/bin/sh
# AbyssBSD Swift DE — launching confined (PHASE18 P18.5).
#
# The session's half: `abyss-jail serve` holds a jail per class, with the
# jail's own Wayland socket, bus and portal, and starts programs in it when
# a launcher asks. Real processes: abyss-jaild as root, undertow, abyss-portal,
# the keeper, and GTK applications. FreeBSD only; needs passwordless sudo.
# Claims:
#
#   1. a launch puts zenity in the class's jail: undertow names its window as
#      that jail's, and the keeper brought up the socket, bus and portal;
#   2. a second application goes into the same jail (pooled, not one per
#      launch);
#   3. a file handed to a launch is granted and rewritten — the program, in
#      the jail, edits the real file in place;
#   4. inside, the runtime directory holds the jail's socket and bus and
#      nothing of the session's, and the portal answers on that bus;
#   5. an application bundle made by abyss-appgen for an app listed in
#      jails.ini's [apps] launches confined, and one not listed does not;
#   6. when the session's keeper ends, the jail, its mounts, its bus and its
#      applications all go.
#
# Usage: abyss/tests/live-jail-launch.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for t in gdbus zenity galculator; do command -v $t > /dev/null || { echo "FAIL: $t not installed"; exit 1; }; done
for b in abyss-jaild abyss-jail abyss-portal abyss-dbus abyss-appgen undertow; do [ -x .build/debug/$b ] || swift build; done

W=$(mktemp -d /tmp/abyss-jl.XXXXXX); chmod 755 "$W"
mkdir "$W/bin"; cp .build/debug/abyss-jaild "$W/bin/"; chmod 755 "$W/bin" "$W/bin/"*
RB="$W/roots" HB="$W/homes" SOCK="$W/jd.sock"
uid=$(id -u)
N="abyss-$uid-app"
export XDG_RUNTIME_DIR="$W/xdg"; mkdir -m 700 "$XDG_RUNTIME_DIR"
docs=$(mktemp -d /tmp/abyss-jld.XXXXXX); printf 'original\n' > "$docs/note.txt"

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
# The mount points under the roots, for cleanup. From plain `mount`, whose
# lines are "SOURCE on POINT (TYPE, …)": `mount -p` cannot be split at all when
# a path has a space — its separator before the mount point is sometimes one
# space (HANDOFF §2.127).
mountsunder() { mount | grep -F " on $RB/" | sed -E 's/^.* on (.*) \([a-z0-9]+[,)].*$/\1/'; }
cleanup() {
  for p in ${kp:-} ${pt:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E '^abyss-[0-9]+-' || true); do sudo jail -r "$j" 2>/dev/null || true; done
  mountsunder | sort -r | while IFS= read -r m; do sudo umount -f "$m" 2>/dev/null || true; done
  pkill -f "endpoint --listen $RB" 2>/dev/null || true
  sudo rm -rf "$W" "$docs"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in jd.log keeper.log; do tail -5 "$W/$f" 2>/dev/null | sed "s/^/  $f| /"; done
         grep -E '^window|^stack' "$W/ut.out" 2>/dev/null | tail -6 | sed "s/^/  undertow| /"; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
JL() { .build/debug/abyss-jail launch "$@"; }
# Counted by mount POINT from plain `mount` (" on $RB/"), never by splitting
# `mount -p`, whose fields cannot be told apart when a path has a space —
# `awk '{print $2}'` once counted a left grant as gone (HANDOFF §2.127). And
# never with jaild's own code, which is what is tested.
mounts() { mount | grep -cF " on $RB/" || true; }

sudo "$W/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$W/jd.log" 2>&1 &
await "$W/jd.log" 'answering at' "the daemon did not start"
env -u WAYLAND_DISPLAY .build/debug/undertow run --hz 60 --frames 0 --width 1024 --height 768 \
    --config-dir "$W" > "$W/ut.out" 2> "$W/ut.err" & ut=$!
await "$W/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$W/ut.out" | cut -d= -f2-)"
.build/debug/abyss-portal > "$W/pt.log" 2>&1 & pt=$!
.build/debug/abyss-jail --socket "$SOCK" serve > "$W/keeper.log" 2>&1 & kp=$!
await "$W/keeper.log" '^jails: ready' "the keeper did not start"

# --------------------------------------------------------------- 1. zenity
JL app -- zenity --info --text "confined" > "$W/l1" 2>&1 || fail "the launch was refused: $(cat "$W/l1")"
await "$W/keeper.log" "jails: $N is jail [0-9]*; its socket, bus, portal and menus are up" "the keeper did not bring the jail up"
jid=$(sed -n "s/jails: $N is jail \([0-9]*\);.*/\1/p" "$W/keeper.log" | head -1)
await "$W/ut.out" "^window-jail zenity/[^ ]* engine=org.abyssbsd.jail app=app instance=$jid$" \
  "undertow did not name zenity's window as jail $jid's"
echo "ok: 1. zenity launched into $N (jail $jid), its window named as that jail's"

# ---------------------------------------------------------- 2. pooled
JL app -- galculator > "$W/l2" 2>&1 || fail "the second launch was refused: $(cat "$W/l2")"
await "$W/ut.out" "^window-jail galculator[^ ]* engine=org.abyssbsd.jail app=app instance=$jid$" \
  "galculator did not land in the same jail ($jid)"
[ "$(count "jaild: $N is jail" "$W/jd.log")" = 1 ] || fail "a second launch made a second jail"
[ "$(count "jails: $N is jail" "$W/keeper.log")" = 1 ] || fail "the keeper brought the jail up again for a second launch"
echo "ok: 2. galculator went into the same jail: one jail per class, not per launch"

# --------------------------------------------------- 3. a file, in place
JL app -- sh -c 'echo "edited in the jail" >> "$1"' sh "$docs/note.txt" > "$W/l3" 2>&1 || fail "the file launch was refused: $(cat "$W/l3")"
await "$W/keeper.log" "jails: $docs/note.txt is /run/granted/1/note.txt in $N" "the file was not granted"
i=0; while ! grep -q "edited in the jail" "$docs/note.txt" && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
[ "$(cat "$docs/note.txt")" = "$(printf 'original\nedited in the jail')" ] || fail "the real file was not edited in place: $(cat "$docs/note.txt")"
echo "ok: 3. a file handed to a launch was granted, and the jail edited the real one in place"

# ---------------------------------------- 4. inside: its own runtime and bus
.build/debug/abyss-jail --socket "$SOCK" run app -- ls /run/user > "$W/rt" 2>&1 || fail "could not look inside: $(cat "$W/rt")"
[ "$(sort "$W/rt" | tr '\n' ' ')" = "bus wayland-0 " ] || fail "the jail's runtime directory holds: $(tr '\n' ' ' < "$W/rt")"
.build/debug/abyss-jail --socket "$SOCK" run app -- gdbus call --session --dest org.freedesktop.DBus \
  --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner org.freedesktop.portal.Desktop > "$W/own" 2>&1
grep -q '(true,)' "$W/own" || fail "the portal does not answer on the jail's bus: $(cat "$W/own")"
echo "ok: 4. inside, only the jail's own socket and bus, and the portal answers there"

# --------------------------------------------------- 5. bundles from appgen
mkdir -p "$W/apps" "$W/Applications" "$W/cfg"
cp /usr/local/share/applications/galculator.desktop "$W/apps/" 2>/dev/null || fail "no galculator.desktop to build from"
cp /usr/local/share/applications/org.gnome.Zenity.desktop "$W/apps/" 2>/dev/null || printf '[Desktop Entry]\nType=Application\nName=Zenity\nExec=zenity --info\n' > "$W/apps/org.gnome.Zenity.desktop"
printf '[apps]\ngalculator = app\n' > "$W/cfg/jails.ini"
.build/debug/abyss-appgen --from "$W/apps" --to "$W/Applications" --jails "$W/cfg/jails.ini" > "$W/gen.log" 2>&1 || fail "appgen failed: $(cat "$W/gen.log")"
grep -q "galculator.desktop.*confined in app" "$W/gen.log" || fail "appgen did not say galculator is confined: $(cat "$W/gen.log")"
grep -q "Zenity.desktop.*confined" "$W/gen.log" && fail "appgen confined Zenity, which jails.ini does not list"
gl=$(find "$W/Applications" -path '*Contents/MacOS/*' -name '*alculator*' | head -1)
grep -q '^exec abyss-jail launch app -- ' "$gl" || fail "galculator's launcher does not launch confined: $(tail -1 "$gl")"
# The bundle's galculator is a window of its own beside the first, and
# undertow says which jail each window came from (per window, not per name).
before=$(count '^window-jail galculator' "$W/ut.out")
PATH="$root/.build/debug:$PATH" sh "$gl" > "$W/l5" 2>&1 || fail "the bundle's launcher failed: $(cat "$W/l5")"
await "$W/ut.out" "^window-jail galculator[^ ]* engine=org.abyssbsd.jail app=app instance=$jid$" \
  "the bundle did not launch galculator into the jail" $((before + 1))
echo "ok: 5. appgen made a confined launcher for the listed app only, and the bundle launched into the jail"

# --------------------------------------------------- 6. the session ends
kill "$kp"; wait "$kp" 2>/dev/null || true
i=0; while { jls -d -j "$N" > /dev/null 2>&1 || [ "$(mounts)" != 0 ]; } && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
jls -j "$N" > /dev/null 2>&1 && fail "the jail outlived the session's keeper"
jls -d -j "$N" > /dev/null 2>&1 && fail "the jail is removed but still dying (unreaped programs?): $(ps -axo pid,jid,stat,comm | awk -v j="$(jls -d -j "$N" jid)" '$2 == j' | tr '\n' '|')"
[ "$(mounts)" = 0 ] || fail "$(mounts) mount(s) outlived the keeper"
sleep 0.5
pgrep -f "abyss-dbus --endpoint --listen $RB" > /dev/null && fail "the jail's D-Bus bridge outlived the keeper"
pgrep -f "abyss-dbus --bus unix:path=$RB" > /dev/null && fail "the jail's portal outlived the keeper"
pgrep -x zenity > /dev/null && pgrep -x zenity | xargs ps -o jid= -p | grep -qv '^ *0$' && fail "a jailed zenity outlived the keeper"
echo "ok: 6. the keeper ended, and the jail, its mounts, its bus, its portal and its applications went with it"
echo "all green (launched confined: a jail per class, its own socket and bus, files in place, gone with the session)."
