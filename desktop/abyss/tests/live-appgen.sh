#!/bin/sh
# AbyssBSD Swift DE — every installed port as an application (PHASE15 P15.1).
#
# `abyss-appgen` turns desktop entries into bundles the Finder and the Dock
# understand. Claims, on fixture entries written here and — where the machine
# has it — on a real port's (galculator, in the FreeBSD guest):
#
#   1. an application becomes `<Name>.app`: a launcher that execs its command,
#      an icon (an SVG rasterised to 256 px), and the marker that makes it ours;
#      a NoDisplay handler, a Hidden entry and a program that is not installed
#      (TryExec) are skipped, each with why; a terminal program (`Terminal=true`)
#      becomes a bundle that opens it in Terminal (P15.4);
#   2. a bundle somebody else put there, under the same name, is kept;
#   3. an entry that goes away takes its generated bundle with it — and only it;
#   4. the generated launcher, run as the Finder runs it, puts the application's
#      window on our compositor (undertow reports it mapped) — and the terminal
#      program's opens a Terminal window running it;
#   6. the desktop's own applications (P18.13 loose ends) become bundles
#      in Jaguar's layout: System Preferences and TextEdit in the folder, the
#      utilities in Utilities, no Finder; each with its theme icon and app_id.
#      Agent is there while agents are on and goes when they are turned off,
#      taking nothing else. A person's run makes only what the machine's
#      folder lacks, and removes its own copy once the machine has one. A
#      built-in's launcher, run as the Finder runs it, maps its window;
#   5. FreeBSD, with galculator installed: its real entry becomes
#      Galculator.app with a 256 px icon from its hicolor SVG, and running it
#      maps galculator's window.
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
# What a launcher names: the binary's real path, so it runs from anywhere.
demo_real=$(realpath "$demo")
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
for w in "handler.desktop: NoDisplay" "hidden.desktop: Hidden" \
         "absent.desktop: no-such-program-here is not installed"; do
  grep -q "^skip $w" "$work/gen.out" || fail "not skipped with its reason: $w"
done
for n in Handler Gone Absent; do [ -e "$apps/$n.app" ] && fail "$n.app was made"; done
grep -q "^exec env AQUA_SCENE=terminal $demo_real -e top\$" "$apps/Top.app/Contents/MacOS/Top" \
  || fail "Top.app does not open top in Terminal: $(cat "$apps/Top.app/Contents/MacOS/Top" 2>&1)"
echo "ok: 1. an application became a bundle (launcher, icon $([ "$svg" = 1 ] && echo "rasterised from SVG to 256 px" || echo "copied from a PNG"), marker); a terminal program's opens it in Terminal; three others skipped, each with why"

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
env WAYLAND_DISPLAY="$wd" HOME="$work" ABYSS_TERMINAL_DUMP=1 "$apps/Top.app/Contents/MacOS/Top" > "$work/top.log" 2>&1 &
app_pid=$!
mapped org.abyssbsd.terminal || fail "Top.app mapped no Terminal window: $(tail -3 "$work/top.log")"
i=0; until grep -q 'Terminal: window: top (pid' "$work/top.log"; do
  [ $i -ge 50 ] && fail "Top.app's Terminal is not running top: $(grep Terminal: "$work/top.log" | head -3)"; sleep 0.1; i=$((i + 1)); done
kill "$app_pid" 2>/dev/null || true; app_pid=""
echo "ok: 4. the generated launcher, run as the Finder runs it, mapped the application's window on undertow; Top.app opened a Terminal running top"

# ------------------------------------------------------------ 6. the desktop's own
export ABYSS_CONFIG_DIR="$work/cfg"; mkdir -p "$ABYSS_CONFIG_DIR"   # agents off: no agents.ini
own="$work/Own"; sys="$work/System"; mkdir -p "$sys"
"$appgen" --from "$ents" --to "$own" --system "$sys" > "$work/gen.out" 2>&1 || fail "abyss-appgen (the desktop's own) failed"
for b in "System Preferences.app:sysprefs:org.abyssbsd.preferences:prefs" "TextEdit.app:textedit:org.abyssbsd.textedit" \
         "Utilities/Terminal.app:terminal:org.abyssbsd.terminal" "Utilities/Grab.app:grab:org.abyssbsd.grab" \
         "Utilities/Activity Monitor.app:activity:org.abyssbsd.activitymonitor" \
         "Utilities/Disk Utility.app:diskutility:org.abyssbsd.diskutility" \
         "Utilities/System Profiler.app:systemprofiler:org.abyssbsd.systemprofiler"; do
  rel=${b%%:*}; rest=${b#*:}; tok=${rest%%:*}; id=${rest#*:}
  ic=$tok; case "$id" in *:*) ic=${id#*:}; id=${id%%:*} ;; esac   # the icon, when it is not the token
  d="$own/$rel"; stem=$(basename "$rel" .app)
  [ -x "$d/Contents/MacOS/$stem" ] || fail "no launcher for $rel"
  grep -q "^AQUA_SCENE=$tok exec $demo_real \"\$@\"\$" "$d/Contents/MacOS/$stem" || fail "$rel's launcher: $(tail -1 "$d/Contents/MacOS/$stem")"
  [ "$(cat "$d/Contents/theme-icon")" = "dock.icon.$ic" ] || fail "$rel's icon is not the theme's dock.icon.$ic"
  [ "$(cat "$d/Contents/app-id")" = "$id" ] || fail "$rel's app_id: $(cat "$d/Contents/app-id")"
  [ "$(cat "$d/Contents/abyss-appgen")" = "builtin:$tok" ] || fail "$rel's marker"
done
[ -e "$own/Finder.app" ] || [ -e "$own/Utilities/Finder.app" ] && fail "a Finder.app was made"
[ -e "$own/Agent.app" ] && fail "Agent.app was made with agents off"
: > "$ABYSS_CONFIG_DIR/agents.ini"
"$appgen" --from "$ents" --to "$own" --system "$sys" > "$work/gen.out" 2>&1 || fail "abyss-appgen failed with agents on"
[ "$(cat "$own/Agent.app/Contents/theme-icon" 2>/dev/null)" = dock.icon.agent ] || fail "no Agent.app with agents on"
before=$(find "$own" -name '*.app' -prune | sort)
rm "$ABYSS_CONFIG_DIR/agents.ini"
"$appgen" --from "$ents" --to "$own" --system "$sys" > "$work/gen.out" 2>&1 || fail "abyss-appgen failed with agents off again"
grep -q "^removed Agent.app: not wanted here now" "$work/gen.out" || fail "Agent.app was not removed with agents off"
[ "$(find "$own" -name '*.app' -prune | sort)" = "$(echo "$before" | grep -v '/Agent.app$')" ] || fail "turning agents off removed more than Agent.app"
# The machine's folder gets Terminal: the person's copy goes, and nothing else.
"$appgen" --from "$ents" --to "$sys" --system "$sys" > /dev/null 2>&1 || fail "abyss-appgen into the machine's folder failed"
[ -d "$sys/Utilities/Terminal.app" ] && [ ! -e "$sys/Agent.app" ] || fail "the machine's folder: $(ls "$sys" "$sys/Utilities" 2>&1 | tr '\n' ' ')"
"$appgen" --from "$ents" --to "$own" --system "$sys" > "$work/gen.out" 2>&1 || fail "abyss-appgen failed after the machine's run"
[ -e "$own/Utilities/Terminal.app" ] && fail "the person's Terminal.app stayed though the machine's folder has one"
grep -q "^removed Utilities/Terminal.app: not wanted here now" "$work/gen.out" || fail "the person's Terminal.app was not removed in words"
"$appgen" --from "$ents" --to "$own" --system "$work/nowhere" > /dev/null 2>&1
env WAYLAND_DISPLAY="$wd" HOME="$work" "$own/Utilities/Grab.app/Contents/MacOS/Grab" > "$work/grab.log" 2>&1 &
app_pid=$!
mapped org.abyssbsd.grab || fail "Grab.app mapped no window: $(tail -3 "$work/grab.log")"
kill "$app_pid" 2>/dev/null || true; app_pid=""
echo "ok: 6. the desktop's own: Jaguar's layout with theme icons, no Finder; Agent with agents on and only then; the machine's copies win; Grab.app runs"

# ------------------------------------------------------------ 5. a real port
kd=/usr/local/share/applications
if [ "$(uname -s)" = FreeBSD ] && [ -f "$kd/galculator.desktop" ]; then
  "$appgen" --from "$kd" --to "$work/Ports" > "$work/gen.out" 2>&1 || fail "abyss-appgen over the real entries failed"
  k="$work/Ports/Galculator.app"
  grep -q "^made Galculator.app from $kd/galculator.desktop (icon: .*galculator.svg at 256px)" "$work/gen.out" \
    || fail "galculator's entry did not become Galculator.app with its SVG icon"
  env WAYLAND_DISPLAY="$wd" GDK_BACKEND=wayland "$k/Contents/MacOS/Galculator" > "$work/galculator.log" 2>&1 &
  app_pid=$!
  mapped galculator || fail "Galculator.app mapped no window: $(tail -3 "$work/galculator.log") (undertow: $(grep -h '^window ' "$work/ut.out" | tr '\n' ' '))"
  echo "ok: 5. galculator's real entry became Galculator.app (icon from its SVG), and it runs"
else
  echo "ok: 5. (no galculator here; the FreeBSD guest runs this half)"
fi

echo "all green (the installed ports, as applications)."
