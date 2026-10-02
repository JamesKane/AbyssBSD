#!/bin/sh
# AbyssBSD Swift DE — the browser (PHASE15 P15.3).
#
# Firefox ESR, the port, launched the way the desktop launches it — through the
# bundle `abyss-appgen` made from its real desktop entry — on our compositor,
# with its file chooser answered by our portal and the Finder. Claims:
#
#   1. the port's entry becomes a bundle whose windows the Dock will know
#      (`Contents/app-id` names `firefox`, which `firefox-esr` matches);
#   2. launched through that bundle, Firefox maps a window on undertow and a
#      local page's colour is on the screen, read back through screencopy;
#   3. clicking the page's file input opens THE FINDER — through
#      `org.freedesktop.portal.FileChooser` on the session bus, because the
#      profile asks for the portal (`widget.use-xdg-desktop-portal.file-picker`);
#   4. the file picked in the Finder reaches the page: the page reads its
#      contents and turns green only if they are the secret written here.
#
# Usage: abyss/tests/live-firefox.sh     (skips where there is no Firefox)
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

entry=""
for d in /usr/local/share/applications /usr/share/applications; do
  for f in firefox.desktop org.mozilla.firefox.desktop firefox-esr.desktop; do
    [ -f "$d/$f" ] && { entry="$d/$f"; break 2; }
  done
done
[ -n "$entry" ] && command -v firefox >/dev/null 2>&1 \
  || { echo "SKIP: no Firefox here (the FreeBSD guest has firefox-esr)"; exit 0; }
for c in gdbus; do command -v $c >/dev/null || { echo "FAIL: $c not installed"; exit 1; }; done

portal="$root/.build/debug/abyss-portal"
bridge="$root/.build/debug/abyss-dbus"
undertow="$root/.build/debug/undertow"
demo="$root/.build/debug/AquaDemo"
appgen="$root/.build/debug/abyss-appgen"
grab="$root/.build/debug/abyssgrab"
for b in "$portal" "$bridge" "$undertow" "$demo" "$appgen" "$grab"; do [ -x "$b" ] || { swift build; break; }; done

W=1024; H=768
work=$(mktemp -d /tmp/abyss-ff.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-ffr.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${ff_pid:-} ${bridge_pid:-} ${portal_pid:-} ${ut_pid:-} ${abyss_bridge_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  pkill -f "$work/profile" 2>/dev/null || true   # Firefox's content processes
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() {
  exec 1>&2
  echo "FAIL: $1"
  for l in ff.err bridge.err portal.log; do
    [ -s "$work/$l" ] && { echo "-- $l"; tail -8 "$work/$l"; }
  done
  exit 1
}
export ABYSS_RUNTIME_DIR="$rundir"

# ------------------------------------------------------------ 1. the bundle
"$appgen" --from "$(dirname "$entry")" --to "$work/Applications" > "$work/gen.out" 2>&1 \
  || fail "abyss-appgen over the real entries failed: $(tail -3 "$work/gen.out")"
app=$(grep "^made .* from $entry " "$work/gen.out" | sed 's/^made \(.*\.app\) from .*/\1/')
[ -n "$app" ] || fail "Firefox's entry made no bundle: $(grep "$entry" "$work/gen.out")"
bundle="$work/Applications/$app"
launcher="$bundle/Contents/MacOS/${app%.app}"
[ -x "$launcher" ] || fail "no launcher in $app"
grep -qx 'firefox' "$bundle/Contents/app-id" || fail "$app's app-ids: $(cat "$bundle/Contents/app-id")"
echo "ok: 1. Firefox's entry became $app (icon: $(grep "^made $app" "$work/gen.out" | sed 's/.*(icon: \(.*\))/\1/'); app-ids: $(tr '\n' ' ' < "$bundle/Contents/app-id"))"

# ------------------------------------------------------------ the pointer
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "no vpointer"

# ------------------------------------------------------------ the bus
# ADE's own D-Bus bridge (BACKLOG D.1): nothing on it is started by name, so a
# desktop's own xdg-desktop-portal cannot answer in our place.
abyss_bridge_start "$work" || exit 1

# ------------------------------------------------------------ the compositor
# The picker's place is seeded, so the click on a file is a fact (live-gtk.sh).
cfgdir="$work/config"; mkdir -p "$cfgdir"
cat > "$cfgdir/windows.ini" <<EOF
[windows]
org.abyssbsd.finder = 0,0
org.abyssbsd.finder/home = 0,0
EOF
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width $W --height $H --config-dir "$cfgdir" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ] && [ -z "$wd" ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""; sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
export WAYLAND_DISPLAY="$wd"

"$portal" > "$work/portal.log" 2>&1 &
portal_pid=$!
i=0; while [ $i -lt 50 ] && [ ! -S "$rundir/portal.sock" ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$rundir/portal.sock" ] || fail "abyss-portal never bound its socket"
env DBUS_SESSION_BUS_ADDRESS="$ABYSS_BRIDGE_SERVICES" "$bridge" > "$work/bridge.out" 2>"$work/bridge.err" &
bridge_pid=$!
i=0; while [ $i -lt 60 ] && ! grep -q '^ready' "$work/bridge.out" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
grep -q '^ready' "$work/bridge.out" || fail "abyss-dbus never came up"

# ------------------------------------------------------------ the page
# Firefox names no folder, so the portal opens the Finder on the home directory
# — which is where a person's files are, so that is where these go.
docs="$work/home"; mkdir -p "$docs"
secret="picked in the Finder $$"
printf '%s\n' "$secret" > "$docs/Chosen file.txt"
printf 'not this one\n' > "$docs/Other.txt"
# One colour, and a file input over all of it: a click anywhere is a click on
# the input. Green only if the file the page was given holds the secret.
cat > "$work/page.html" <<EOF
<!doctype html><meta charset="utf-8"><title>pick</title>
<style>html,body{margin:0;height:100%;background:#e8b04c}
input{position:fixed;left:0;top:0;width:100%;height:100%;opacity:0}</style>
<input type="file" id="f">
<script>
document.getElementById('f').onchange = async (e) => {
  const file = e.target.files[0], text = (await file.text()).trim();
  document.title = 'picked ' + file.name;
  document.body.style.background = text === '$secret' ? '#2e8b57' : '#b22222';
};
</script>
EOF
# A profile of our own: the portal for files, and no first-run pages over ours.
mkdir -p "$work/profile"
cat > "$work/profile/user.js" <<'EOF'
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.tabs.warnOnClose", false);
EOF

# ------------------------------------------------------------ 2. it renders
# Through the bundle's launcher, which passes its arguments on (P15.1).
env -u DISPLAY HOME="$work/home" GTK_USE_PORTAL=1 "$launcher" --no-remote --profile "$work/profile" \
    --kiosk "file://$work/page.html" > "$work/ff.out" 2> "$work/ff.err" &
ff_pid=$!
i=0; until grep -qE '^window (org\.mozilla\.)?firefox' "$work/ut.out"; do
  [ $i -ge 300 ] && fail "Firefox mapped no window in 30 s: $(grep '^window' "$work/ut.out")"
  kill -0 "$ff_pid" 2>/dev/null || fail "Firefox exited"
  sleep 0.1; i=$((i + 1))
done
ffwin=$(grep -m1 -E '^window (org\.mozilla\.)?firefox' "$work/ut.out")
pixel() {  # pixel X Y — the output's colour there, through screencopy
  "$grab" "$work/shot.ppm" 2>/dev/null || fail "could not grab the screen"
  hdr=$(printf 'P6\n%s %s\n255\n' $W $H | wc -c | tr -d ' ')
  dd if="$work/shot.ppm" bs=1 skip=$((hdr + ($2 * W + $1) * 3)) count=3 2>/dev/null | od -An -v -tu1 | awk '{print $1, $2, $3}'
}
# Off-centre: the pointer rests at the centre (HANDOFF §2.85); away from where
# the picker will open at 0,0.
want="232 176 76"; i=0
until [ "$(pixel 900 700)" = "$want" ]; do
  [ $i -ge 100 ] && fail "the page's colour never reached the screen: (900,700) is $(pixel 900 700)"
  sleep 0.2; i=$((i + 1))
done
echo "ok: 2. launched through its bundle, Firefox mapped ($ffwin) and the page is on screen (#e8b04c at 900,700)"

# What Firefox publishes on the bus, for PHASE15 §6.3 (menus in our bar): said,
# not asserted — no claim rests on it yet.
sleep 1
names=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.ListNames 2>/dev/null | tr -d "(),[]'" | tr ' ' '\n' | grep -v '^:' | grep -v '^org.freedesktop.DBus$' | tr '\n' ' ')
echo "note: well-known names on the bus with Firefox up: $names"

# ------------------------------------------------------------ 3. the picker
mkfifo "$work/pointer"
"$work/vpointer" $W $H < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
sleep 1
printf 'm 900 700\np\nr\n' >&3
i=0; until grep -q 'Finder: listed' "$work/portal.log" 2>/dev/null; do
  [ $i -ge 150 ] && fail "clicking the file input did not open the Finder"
  sleep 0.1; i=$((i + 1))
done
grep -q 'asked for OpenFile' "$work/bridge.err" || fail "the Finder opened, but not through OpenFile on the bus"
echo "ok: 3. the page's file input opened the Finder, through org.freedesktop.portal.FileChooser"

# ------------------------------------------------------------ 4. the file
sleep 1.5
grep -q "Finder: listed $docs" "$work/portal.log" \
  || fail "the picker is not on $docs: $(grep 'Finder: listed' "$work/portal.log" | tail -1)"
printf 'm 54 96\np\nr\np\nr\n' >&3
want="46 139 87"; i=0
until [ "$(pixel 900 700)" = "$want" ]; do
  [ $i -ge 100 ] && fail "the page never turned green: (900,700) is $(pixel 900 700) (red is the wrong file)"
  sleep 0.2; i=$((i + 1))
done
grep -q "handing over $docs/Chosen file.txt" "$work/portal.log" || fail "the portal did not hand over the chosen file"
echo "ok: 4. the file picked in the Finder reached the page, which read the secret in it"

# ABYSS_FF_MAPS=FILE: every object mapped into Firefox's processes, now that it
# has rendered and been through the portal — what the medium must carry,
# including what Firefox `dlopen`s and `ldd` cannot see (P15.3b). FreeBSD.
if [ -n "${ABYSS_FF_MAPS:-}" ] && command -v procstat >/dev/null 2>&1; then
  for p in $(pgrep -f "$work/profile"); do procstat -v "$p" 2>/dev/null; done \
    | awk '$NF ~ /^\// {print $NF}' | sort -u > "$ABYSS_FF_MAPS"
fi

echo "all green (the browser: Firefox through its bundle, on undertow, with the Finder as its file chooser)."
