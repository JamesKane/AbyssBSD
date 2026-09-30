#!/bin/sh
# AbyssBSD Swift DE — every installed port as an application (PHASE15 P15.1).
#
# `abyss-appgen` turns desktop entries into bundles the Finder and the Dock
# understand. Claims, on fixture entries written here and — where the machine
# has it — on a real port's (kcalc, in the FreeBSD guest):
#
#   1. an application becomes `<Name>.app`: a launcher that execs its command,
#      an icon (an SVG rasterised to 256 px), and the marker that makes it ours;
#      a NoDisplay handler, a Hidden entry, a terminal program (no Terminal yet)
#      and a program that is not installed (TryExec) are skipped, each with why;
#   2. a bundle somebody else put there, under the same name, is kept;
#   3. an entry that goes away takes its generated bundle with it — and only it;
#   4. the generated launcher, run as the Finder runs it, puts the application's
#      window on our compositor (undertow reports it mapped);
#   5. FreeBSD, with kcalc installed: its real entry becomes KCalc.app with a
#      256 px icon from breeze's SVG, and running it maps kcalc's window.
#
# Usage: abyss/tests/live-appgen.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

appgen="$root/.build/debug/abyss-appgen"
undertow="$root/.build/debug/undertow"
demo="$root/.build/debug/AquaDemo"
for b in "$appgen" "$undertow" "$demo"; do [ -x "$b" ] || { swift build; break; }; done
# The SVG half needs rsvg-convert (librsvg; the guest has it with GTK). Without
# it the fixture's icon is a PNG from the tree, and only the rasterising is not
# checked — said, not silently skipped.
if command -v rsvg-convert >/dev/null 2>&1; then
  icon="$root/abyss/tests/svg/beacon.svg"; svg=1
else
  icon="$root/docs/screenshots/first-window.png"; svg=0
  echo "note: no rsvg-convert here — the icon is a PNG, and rasterising an SVG is the guest's to check"
fi

work=$(mktemp -d /tmp/abyss-appgen.XXXXXX)
cleanup() {
  for p in ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; [ -s "$work/gen.out" ] && sed 's/^/  appgen| /' "$work/gen.out" | tail -12; exit 1; }

apps="$work/Applications"; ents="$work/entries"; mkdir -p "$ents"
cat > "$ents/org.abyssbsd.window.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Aqua Window
Name[de]=Aqua-Fenster
Exec=env AQUA_SCENE=window "$demo" %F
Icon=$icon
EOF
printf '[Desktop Entry]\nType=Application\nName=Handler\nExec=handler %%u\nNoDisplay=true\n' > "$ents/handler.desktop"
printf '[Desktop Entry]\nType=Application\nName=Gone\nExec=gone\nHidden=true\n' > "$ents/hidden.desktop"
printf '[Desktop Entry]\nType=Application\nName=Top\nExec=top\nTerminal=true\n' > "$ents/top.desktop"
printf '[Desktop Entry]\nType=Application\nName=Absent\nExec=absent\nTryExec=no-such-program-here\n' > "$ents/absent.desktop"
printf '[Desktop Entry]\nType=Application\nName=Ephemeral\nExec=true\n' > "$ents/ephemeral.desktop"
printf '[Desktop Entry]\nType=Application\nName=Mine\nExec=true\n' > "$ents/mine.desktop"
# Somebody else's bundle, under a name an entry also wants.
mkdir -p "$apps/Mine.app/Contents/MacOS"
printf '#!/bin/sh\necho mine\n' > "$apps/Mine.app/Contents/MacOS/Mine"; chmod 755 "$apps/Mine.app/Contents/MacOS/Mine"

# ------------------------------------------------------------ 1. the bundles
"$appgen" --from "$ents" --to "$apps" > "$work/gen.out" 2>&1 || fail "abyss-appgen failed"
b="$apps/Aqua Window.app"
if [ "$svg" = 1 ]; then
  grep -q "^made Aqua Window.app from $ents/org.abyssbsd.window.desktop (icon: .*beacon.svg at 256px)" "$work/gen.out" \
    || fail "no Aqua Window.app with its SVG icon"
else
  grep -q "^made Aqua Window.app from $ents/org.abyssbsd.window.desktop (icon: $icon)" "$work/gen.out" \
    || fail "no Aqua Window.app with its PNG icon"
fi
[ -x "$b/Contents/MacOS/Aqua Window" ] || fail "no launcher in the bundle"
grep -q '^exec env AQUA_SCENE=window .*AquaDemo "\$@"$' "$b/Contents/MacOS/Aqua Window" \
  || fail "the launcher: $(cat "$b/Contents/MacOS/Aqua Window")"
[ "$(od -An -tx1 -N8 "$b/Contents/Resources/Aqua Window.png" | tr -d ' ')" = "89504e470d0a1a0a" ] \
  || fail "the icon is not a PNG"
[ "$svg" = 0 ] || [ "$(od -An -tu1 -j16 -N8 "$b/Contents/Resources/Aqua Window.png" | awk '{print $3*256+$4, $7*256+$8}')" = "256 256" ] \
  || fail "the icon is not 256 px square"
[ -s "$b/Contents/abyss-appgen" ] || fail "no marker"
for w in "handler.desktop: NoDisplay" "hidden.desktop: Hidden" "top.desktop: needs a terminal" \
         "absent.desktop: no-such-program-here is not installed"; do
  grep -q "^skip $w" "$work/gen.out" || fail "not skipped with its reason: $w"
done
for n in Handler Gone Top Absent; do [ -e "$apps/$n.app" ] && fail "$n.app was made"; done
echo "ok: 1. an application became a bundle (launcher, icon $([ "$svg" = 1 ] && echo "rasterised from SVG to 256 px" || echo "copied from a PNG"), marker); four others skipped, each with why"

# ------------------------------------------------------------ 2. not ours
grep -q "^kept Mine.app: it is not ours" "$work/gen.out" || fail "somebody else's Mine.app was not kept"
[ "$("$apps/Mine.app/Contents/MacOS/Mine")" = mine ] || fail "somebody else's Mine.app was changed"
echo "ok: 2. a bundle that is not ours, under the same name, was left as it was"

# ------------------------------------------------------------ 3. gone
rm "$ents/ephemeral.desktop"
"$appgen" --from "$ents" --to "$apps" > "$work/gen.out" 2>&1 || fail "abyss-appgen failed the second time"
grep -q "^removed Ephemeral.app: its entry .*ephemeral.desktop is gone" "$work/gen.out" || fail "Ephemeral.app was not removed"
[ -e "$apps/Ephemeral.app" ] && fail "Ephemeral.app is still there"
[ -d "$apps/Mine.app" ] && [ -d "$b" ] || fail "the second run removed something that was not gone"
echo "ok: 3. a gone entry's bundle was removed, and nothing else"

# ------------------------------------------------------------ 4. it runs
W=1024; H=768
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 1800 --width $W --height $H \
  > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; wd=""
while [ $i -lt 100 ] && [ -z "$wd" ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""; sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never came up"
mapped() {  # mapped APP_ID — wait for undertow's `window APP_ID/TITLE X,Y WxH` line
  i=0                           # (after its warm-up, HANDOFF §2.83: so up to 15 s)
  while [ $i -lt 150 ]; do
    grep -q "^window $1/" "$work/ut.out" && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
env WAYLAND_DISPLAY="$wd" "$b/Contents/MacOS/Aqua Window" > "$work/app.log" 2>&1 &
app_pid=$!
mapped org.abyssbsd.aquademo || fail "running the bundle mapped no window (undertow reported: $(grep -h "^window " "$work/ut.out" | tr "\n" " "))"
kill "$app_pid" 2>/dev/null || true; app_pid=""
echo "ok: 4. the generated launcher, run as the Finder runs it, mapped the application's window on undertow"

# ------------------------------------------------------------ 5. a real port
kd=/usr/local/share/applications
if [ "$(uname -s)" = FreeBSD ] && [ -f "$kd/org.kde.kcalc.desktop" ]; then
  "$appgen" --from "$kd" --to "$work/Ports" > "$work/gen.out" 2>&1 || fail "abyss-appgen over the real entries failed"
  k="$work/Ports/KCalc.app"
  grep -q "^made KCalc.app from $kd/org.kde.kcalc.desktop (icon: .*accessories-calculator.svg at 256px)" "$work/gen.out" \
    || fail "kcalc's entry did not become KCalc.app with its breeze icon"
  env WAYLAND_DISPLAY="$wd" QT_QPA_PLATFORM=wayland "$k/Contents/MacOS/KCalc" > "$work/kcalc.log" 2>&1 &
  app_pid=$!
  mapped org.kde.kcalc || fail "KCalc.app mapped no window: $(tail -3 "$work/kcalc.log")"
  echo "ok: 5. kcalc's real entry became KCalc.app (icon from breeze's SVG), and it runs"
else
  echo "ok: 5. (no kcalc here; the FreeBSD guest runs this half)"
fi

echo "all green (the installed ports, as applications)."
