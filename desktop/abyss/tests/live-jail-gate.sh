#!/bin/sh
# AbyssBSD Swift DE — the gate for applications in jails (PHASE18 P18.6).
#
# 18a end to end, as a person meets it: jails.ini's [apps] lists three
# applications; abyss-appgen makes their bundles; the session's keeper
# launches them confined; Firefox, confined in app-net, loads a page over the
# network and is handed a file through the Finder; the menu bar says it is
# confined; and a change to [apps] remakes the bundles. Real everything:
# abyss-jaild as root, undertow with its privileged socket, abyss-portal and
# the Finder, the keeper, the menu bar, Firefox ESR, galculator, zenity.
# FreeBSD only; needs passwordless sudo. Claims:
#
#   1. the bundles of the listed applications launch confined — galculator in
#      app, Firefox in app-net — and an unlisted one does not;
#   2. galculator by its bundle, and zenity by `abyss-jail launch` (the guest
#      has no entry for it), map windows undertow names as the app jail's;
#   3. Firefox, by its bundle, maps a window named as app-net's and renders a
#      page served over the network (loopback; app-net has the host's);
#   4. the page's file input opens the Finder through the jail's portal; the
#      file chosen is granted, and the page reads the right one through it;
#   5. inside app-net, the real home's .ssh is not there — the home is the
#      jail's own;
#   6. with Firefox frontmost, the menu bar's application menu says
#      "Confined (app-net)", disabled;
#   7. taking galculator out of [apps] remakes the bundles, and its launcher
#      is no longer confined.
#
# Usage: abyss/tests/live-jail-gate.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ "$(uname -s)" = FreeBSD ] || { echo "note: jails are FreeBSD's — skipping on $(uname -s)"; exit 0; }
sudo -n true 2>/dev/null || { echo "FAIL: this needs passwordless sudo (the daemon runs as root)"; exit 1; }
for t in firefox zenity galculator perl wayland-scanner; do command -v $t > /dev/null || { echo "FAIL: $t not installed"; exit 1; }; done
for b in abyss-jaild abyss-jail abyss-portal abyss-dbus abyss-appgen undertow abyssgrab AquaDemo; do [ -x .build/debug/$b ] || swift build; done
D=.build/debug
W=1024; H=768

T=$(mktemp -d /tmp/abyss-jg.XXXXXX); chmod 755 "$T"
mkdir "$T/bin"; cp $D/abyss-jaild "$T/bin/"; chmod 755 "$T/bin" "$T/bin/"*
RB="$T/roots" HB="$T/homes" SOCK="$T/jd.sock"
me=$(id -un)
export XDG_RUNTIME_DIR="$T/xdg"; mkdir -m 700 "$XDG_RUNTIME_DIR"
export ABYSS_RUNTIME_DIR="$XDG_RUNTIME_DIR"
export ABYSS_CONFIG_DIR="$T/cfg"; mkdir -p "$ABYSS_CONFIG_DIR"
export HOME="$T/home"; mkdir -p "$HOME"
secret="chosen through the jail $$"
# The person's documents, where the Finder opens (the portal's home): apart
# from $HOME, which gets the Applications folder the bundles go in.
# Named home: windows.ini places the Finder by its title (org.abyssbsd.finder/home).
docs="$T/person/home"; mkdir -p "$docs"
printf '%s\n' "$secret" > "$docs/Chosen file.txt"; printf 'not this one\n' > "$docs/Other.txt"

daemon() { pgrep -f "abyss-jaild --socket $SOCK" || true; }
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${http:-} ${bar:-} ${vp:-} ${kp:-} ${pt:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done
  pkill -f "firefox.*$T" 2>/dev/null || true
  for p in $(daemon); do sudo kill -9 "$p" 2>/dev/null || true; done
  for j in $(jls name | grep -E '^abyss-[0-9]+-' || true); do sudo jail -r "$j" 2>/dev/null || true; done
  for m in $(mount -p | awk '{print $2}' | grep "^$RB" | sort -r); do sudo umount -f "$m" 2>/dev/null || true; done
  sudo rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; for f in jd.log keeper.log bar.log pt.log xdg/jails/app-net/bridge.log; do tail -5 "$T/$f" 2>/dev/null | sed "s/^/  $f| /"; done
         grep -E '^window' "$T/ut.out" 2>/dev/null | tail -4 | sed "s/^/  undertow| /"; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt "${5:-200}" ]; do i=$((i + 1)); sleep 0.1; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }
[ -d "/home/$me/.ssh" ] || fail "no real ~/.ssh to look for (claim 5 proves nothing)"
bundle() { find "$HOME/Applications" -path "*Contents/MacOS/*" -iname "$1" | head -1; }
pixel() {  # pixel X Y — the output's colour there, through screencopy
  $D/abyssgrab "$T/shot.ppm" 2>/dev/null || fail "could not grab the screen"
  hdr=$(printf 'P6\n%s %s\n255\n' $W $H | wc -c | tr -d ' ')
  dd if="$T/shot.ppm" bs=1 skip=$((hdr + ($2 * W + $1) * 3)) count=3 2>/dev/null | od -An -v -tu1 | awk '{print $1, $2, $3}'
}

# --------------------------------------------------------------- the session
sudo "$T/bin/abyss-jaild" --socket "$SOCK" --root-base "$RB" --home-base "$HB" > "$T/jd.log" 2>&1 &
await "$T/jd.log" 'answering at' "the daemon did not start"
printf '[windows]\norg.abyssbsd.finder = 0,0\norg.abyssbsd.finder/home = 0,0\n' > "$ABYSS_CONFIG_DIR/windows.ini"
env -u WAYLAND_DISPLAY $D/undertow run --hz 60 --frames 0 --width $W --height $H --config-dir "$ABYSS_CONFIG_DIR" \
    --privileged-socket "$T/priv" > "$T/ut.out" 2> "$T/ut.err" & ut=$!
await "$T/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$T/ut.out" | cut -d= -f2-)"
HOME="$docs" $D/abyss-portal > "$T/pt.log" 2>&1 & pt=$!
printf '[apps]\nfirefox = app-net\ngalculator = app\n' > "$ABYSS_CONFIG_DIR/jails.ini"
$D/abyss-jail --socket "$SOCK" serve > "$T/keeper.log" 2>&1 & kp=$!
await "$T/keeper.log" '^jails: ready' "the keeper did not start"
env WAYLAND_DISPLAY="$T/priv" AQUA_SCENE=menubar $D/AquaDemo > "$T/bar.log" 2>&1 & bar=$!
xml=abyss/tests/wlr-virtual-pointer-unstable-v1.xml
wayland-scanner client-header "$xml" "$T/vpointer-proto.h"; wayland-scanner private-code "$xml" "$T/vpointer-proto.c"
cc -I"$T" abyss/tests/vpointer.c "$T/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$T/vpointer" || fail "vpointer"
mkfifo "$T/vp"; "$T/vpointer" $W $H < "$T/vp" > "$T/vp.log" 2>&1 & vp=$!; exec 3>"$T/vp"

# ------------------------------------------------------------- 1. the bundles
# As anchor does at login (PHASE15 P15.1).
# The guest has two applications and [apps] lists both; an entry of the
# test's own is the one that is not listed.
mkdir -p "$T/apps"; printf '[Desktop Entry]\nType=Application\nName=Unlisted\nExec=true\n' > "$T/apps/unlisted.desktop"
$D/abyss-appgen --from /usr/local/share/applications --from "$T/apps" --to "$HOME/Applications" > "$T/gen.log" 2>&1 \
  || fail "appgen failed: $(tail -3 "$T/gen.log")"
gal=$(bundle '*alculator*'); ff=$(bundle 'firefox*')
[ -n "$gal" ] && [ -n "$ff" ] || fail "missing bundles: galculator='$gal' firefox='$ff'"
grep -q '^exec abyss-jail launch app -- galculator' "$gal" || fail "galculator's launcher: $(tail -1 "$gal")"
grep -q '^exec abyss-jail launch app-net -- firefox' "$ff" || fail "Firefox's launcher: $(tail -1 "$ff")"
other=$(bundle 'Unlisted')
[ -n "$other" ] || fail "the unlisted entry made no bundle: $(grep -i unlisted "$T/gen.log")"
grep -q 'abyss-jail launch' "$other" && fail "an application [apps] does not list launches confined — opt-in is not opt-in"
echo "ok: 1. galculator's bundle launches confined in app, Firefox's in app-net, and the rest ($(basename "$other") among them) do not"

# ------------------------------------------------- 2. galculator and zenity
PATH="$root/$D:$PATH" sh "$gal" > "$T/l-gal" 2>&1 || fail "galculator's bundle: $(cat "$T/l-gal")"
$D/abyss-jail launch app -- zenity --info --text "confined" > "$T/l-zen" 2>&1 || fail "zenity's launch: $(cat "$T/l-zen")"
await "$T/ut.out" '^window-jail galculator[^ ]* engine=org.abyssbsd.jail app=app ' "galculator's window is not the app jail's"
await "$T/ut.out" '^window-jail zenity[^ ]* engine=org.abyssbsd.jail app=app ' "zenity's window is not the app jail's"
echo "ok: 2. galculator by its bundle and zenity by launch mapped windows named as the app jail's"
pkill -x galculator 2>/dev/null || true; pkill -x zenity 2>/dev/null || true

# ------------------------------------------------- 3. Firefox, over the net
cat > "$T/page.html" <<EOF
<!doctype html><meta charset="utf-8"><title>gate</title>
<style>html,body{margin:0;height:100%;background:#e8b04c}
input{position:fixed;left:0;top:0;width:100%;height:100%;opacity:0}</style>
<input type="file" id="f">
<script>
document.getElementById('f').onchange = async (e) => {
  const file = e.target.files[0], text = (await file.text()).trim();
  document.body.style.background = text === '$secret' ? '#2e8b57' : '#b22222';
};
</script>
EOF
perl -MIO::Socket::INET -e '
  my $page = do { local $/; open my $f, "<", $ARGV[0] or die; <$f> };
  my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 0, Listen => 8, ReuseAddr => 1) or die;
  $| = 1; print $s->sockport, "\n";
  while (my $c = $s->accept) { while (<$c>) { last if /^\r?\n$/ }
    print $c "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: " . length($page) . "\r\n\r\n" . $page; close $c }' \
  "$T/page.html" > "$T/http.port" 2>&1 & http=$!
await "$T/http.port" '^[0-9]' "the page server did not start"
port=$(head -1 "$T/http.port")
# Its profile, in the jail's own home: the portal for files, no first-run
# pages. The home is jaild's to make (its parent is root's), so the jail is
# brought up first with a launch that does nothing.
$D/abyss-jail launch app-net -- true > /dev/null 2>&1 || fail "app-net would not come up"
prof="$HB/$me/app-net/ffprof"; mkdir -p "$prof" || fail "cannot make the profile in the jail's home"
cat > "$prof/user.js" <<'EOF'
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("widget.use-xdg-desktop-portal.file-picker", 1);
EOF
PATH="$root/$D:$PATH" sh "$ff" --no-remote --profile "/home/$me/ffprof" --kiosk "http://127.0.0.1:$port/" > "$T/l-ff" 2>&1 \
  || fail "Firefox's bundle: $(cat "$T/l-ff")"
await "$T/ut.out" '^window-jail .*firefox.* engine=org.abyssbsd.jail app=app-net ' "Firefox's window is not app-net's" 1 600
want="232 176 76"; i=0
until [ "$(pixel 900 700)" = "$want" ]; do
  [ $i -ge 150 ] && fail "the page never reached the screen: (900,700) is $(pixel 900 700)"
  sleep 0.2; i=$((i + 1))
done
echo "ok: 3. Firefox, confined in app-net by its bundle, rendered a page served over the network"

# ------------------------------------------------- 4. a file, through the Finder
sleep 1
printf 'm 900 700\np\nr\n' >&3
await "$T/pt.log" 'Finder: listed' "the file input did not open the Finder"
sleep 1.5
grep -q "Finder: listed $docs" "$T/pt.log" || fail "the Finder is not on the person's documents ($docs): $(grep 'Finder: listed' "$T/pt.log" | tail -1)"
printf 'm 54 96\np\nr\np\nr\n' >&3
want="46 139 87"; i=0
until [ "$(pixel 900 700)" = "$want" ]; do
  [ $i -ge 100 ] && fail "the page never turned green: (900,700) is $(pixel 900 700) (red is the wrong file)"
  sleep 0.2; i=$((i + 1))
done
grep -q "jaild: granted $docs/Chosen file.txt to abyss-$(id -u)-app-net at /run/granted/[0-9]*/Chosen file.txt (read-only)" "$T/jd.log" \
  || fail "the file did not come in as a read-only grant: $(grep granted "$T/jd.log" | tail -1)"
echo "ok: 4. the file input opened the Finder through the jail's portal; the chosen file was granted, read-only, and the page read it"

# ------------------------------------------------------- 5. not the real home
$D/abyss-jail --socket "$SOCK" run app-net -- sh -c 'test -e "$HOME/.ssh" && echo SSH; echo "$HOME"; ls -A "$HOME"' > "$T/inside-home" 2>&1
grep -qx SSH "$T/inside-home" && fail "the real ~/.ssh is visible in app-net"
[ "$(sed -n 1p "$T/inside-home")" = "/home/$me" ] || fail "the jail's HOME is $(sed -n 1p "$T/inside-home")"
grep -q "^ffprof$" "$T/inside-home" || fail "the jail's home is not its own: $(tr '\n' ' ' < "$T/inside-home")"
echo "ok: 5. in app-net, \$HOME is the jail's own (ffprof, no .ssh); the real one's .ssh is not there"

# ------------------------------------------------------- 6. the menu bar says so
await "$T/bar.log" 'frontmost is confined in app-net' "the bar was not told Firefox is confined"
t=$(grep '^.*titles ' "$T/bar.log" | tail -1 | tr ' ' '\n' | grep -i 'firefox.*@' | tail -1)
[ -n "$t" ] || fail "the bar shows no Firefox menu: $(grep '@' "$T/bar.log" | tail -1)"
xy=${t#*@}
printf 'm %s %s\np\nr\n' "${xy%,*}" "${xy#*,}" >&3
await "$T/bar.log" "item 'Confined (app-net)' at [0-9]*,[0-9]* disabled app.confined" "the application menu does not say Confined (app-net)"
printf 'm 900 400\np\nr\n' >&3
echo "ok: 6. Firefox frontmost: its application menu says 'Confined (app-net)', disabled"

# ----------------------------------------------- 7. [apps] changes the bundles
printf '[apps]\nfirefox = app-net\n' > "$ABYSS_CONFIG_DIR/jails.ini"
await "$T/keeper.log" "jails.ini's \[apps\] changed; making the applications again" "the keeper did not notice [apps] change"
i=0; while grep -q 'abyss-jail launch' "$(bundle '*alculator*')" && [ $i -lt 300 ]; do i=$((i + 1)); sleep 0.1; done
grep -q 'abyss-jail launch' "$(bundle '*alculator*')" && fail "galculator's launcher is still confined after leaving [apps]"
grep -q '^exec abyss-jail launch app-net -- firefox' "$(bundle 'firefox*')" || fail "Firefox lost its confinement"
echo "ok: 7. galculator left [apps]: the bundles were made again, and its launcher is not confined"
echo "all green (18a's gate: listed applications run confined, reach the network as their class says, get the files they are given, and say so)."
