#!/bin/sh
# AbyssBSD Swift DE — the medium carries a browser that runs (PHASE15 P15.3b).
#
# `live-image.sh --keep` leaves its staging root: base.txz, kernel.txz, and
# exactly what the medium carries in /usr/local — nothing from the builder's
# own /usr/local. Inside it (a chroot), with only that tree to load from:
#
#   1. undertow comes up headless, and Firefox — started through the bundle
#      `abyss-appgen` makes from the medium's own entry, with a fresh profile —
#      maps a window on it;
#   2. its page's colour is read back through screencopy, so it did not just
#      start but rendered;
#   3. what it `dlopen`s — which `live-image.sh` names because `ldd` cannot
#      see it — was there and loaded: NSS's modules (HTTPS) and GTK's Wayland
#      input module are among the objects mapped into its processes.
#
# Cheaper than booting the medium, and it fails for the same missing file.
# FreeBSD only; needs a staging root (run `abyss/mk/live-image.sh --keep`).
#
# Usage: abyss/tests/live-medium-browser.sh [STAGE]   (default /tmp/abyss-live-stage)
set -eu
stage=${1:-${TMPDIR:-/tmp}/abyss-live-stage}
[ "$(uname -s)" = FreeBSD ] || { echo "SKIP: FreeBSD only (a chroot into the medium's tree)"; exit 0; }
[ -x "$stage/usr/local/lib/firefox/firefox" ] \
  || { echo "SKIP: no staged medium with a browser at $stage (abyss/mk/live-image.sh --keep)"; exit 0; }

# **Unmount, or say so.** A devfs left mounted in the staging root makes the next
# `live-image.sh` fail to remove it, and stacks another mount per run. The
# processes are the chroot's, named by pid in run.sh; they must be gone first —
# Firefox takes a moment to take its content processes down.
cleanup() {
  pids=$(sudo cat "$stage/tmp/mb/pids" 2>/dev/null || true)
  [ -n "$pids" ] && sudo kill $pids 2>/dev/null || true
  i=0
  while [ $i -lt 50 ] && mount | grep -q " $stage/dev "; do
    sudo umount "$stage/dev" 2>/dev/null && break
    for p in $pids; do sudo pkill -P "$p" 2>/dev/null || true; done
    sleep 0.2; i=$((i + 1))
  done
  mount | grep -q " $stage/dev " && echo "WARNING: $stage/dev is still mounted — sudo umount -f $stage/dev" >&2
  return 0
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; sudo sh -c "tail -6 '$stage/tmp/mb/ff.err' '$stage/tmp/mb/ut.err'" 2>/dev/null; exit 1; }

sudo mount -t devfs devfs "$stage/dev"
# rc's ldconfig runs at boot; in a chroot nothing has, and /usr/local/lib would
# be invisible to the loader. The paths the medium's rc.conf gives it.
sudo chroot "$stage" /sbin/ldconfig -m /lib /usr/lib /usr/local/lib
sudo rm -rf "$stage/tmp/mb"
sudo mkdir -p "$stage/tmp/mb"
sudo sh -c "cat > '$stage/tmp/mb/page.html'" <<'EOF'
<!doctype html><meta charset="utf-8"><title>medium</title>
<style>html,body{margin:0;height:100%;background:#e8b04c}</style>
EOF
sudo sh -c "cat > '$stage/tmp/mb/run.sh'" <<'EOF'
#!/bin/sh
set -u
export XDG_RUNTIME_DIR=/tmp/mb/xdg HOME=/tmp/mb/home
mkdir -p -m 700 "$XDG_RUNTIME_DIR"; mkdir -p "$HOME" /tmp/mb/profile
cd /tmp/mb
/usr/local/bin/abyss-appgen --from /usr/local/share/applications --to /tmp/mb/Applications > gen.out 2>&1
app=$(sed -n 's/^made \(.*\.app\) from .*firefox.desktop .*/\1/p' gen.out)
[ -n "$app" ] || { echo "no-bundle"; exit 1; }
t0=$(date +%s)
/usr/local/bin/undertow run --frames 0 --width 1024 --height 768 > ut.out 2> ut.err &
echo $! >> /tmp/mb/pids
i=0; until grep -q '^WAYLAND_DISPLAY=' ut.out 2>/dev/null; do i=$((i+1)); [ $i -gt 50 ] && { echo no-undertow; exit 1; }; sleep 0.1; done
export WAYLAND_DISPLAY=$(sed -n 's/^WAYLAND_DISPLAY=//p' ut.out)
"/tmp/mb/Applications/$app/Contents/MacOS/${app%.app}" --no-remote --profile /tmp/mb/profile \
    --kiosk file:///tmp/mb/page.html > ff.out 2> ff.err &
echo $! >> /tmp/mb/pids
i=0; until grep -q '^window firefox' ut.out; do i=$((i+1)); [ $i -gt 300 ] && { echo no-window; exit 1; }; sleep 0.1; done
echo "window $(grep -m1 '^window firefox' ut.out)"
i=0
while [ $i -lt 100 ]; do
  /usr/local/bin/abyssgrab shot.ppm 2>/dev/null
  hdr=$(printf 'P6\n1024 768\n255\n' | wc -c | tr -d ' ')
  rgb=$(dd if=shot.ppm bs=1 skip=$((hdr + (700 * 1024 + 900) * 3)) count=3 2>/dev/null | od -An -v -tu1 | awk '{print $1, $2, $3}')
  if [ "$rgb" = "232 176 76" ]; then
    echo "rendered $rgb via $app after $(( $(date +%s) - t0 )) s"
    for p in $(pgrep firefox); do procstat -v "$p" 2>/dev/null; done | awk '$NF ~ /^\// {print "mapped", $NF}' | sort -u
    exit 0
  fi
  sleep 0.2; i=$((i + 1))
done
echo "blank $rgb"; exit 1
EOF
sudo chmod +x "$stage/tmp/mb/run.sh"
out=$(sudo chroot "$stage" /tmp/mb/run.sh 2>&1) || fail "in the medium's tree: $out"
case "$out" in
  *"rendered 232 176 76 via "*) ;;
  *) fail "unexpected: $out" ;;
esac
echo "ok: 1. in the medium's own tree, Firefox started through its generated bundle ($(echo "$out" | sed -n 's/.*via \(.*\.app\) after.*/\1/p')) and mapped: $(echo "$out" | sed -n 's/^window //p')"
echo "ok: 2. and its page's colour came back through screencopy (#e8b04c), $(echo "$out" | sed -n 's/.* after \([0-9]* s\)$/\1/p') after undertow started"
for want in libsoftokn3.so libfreeblpriv3.so libnssckbi.so im-wayland.so; do
  echo "$out" | grep -q "^mapped .*/$want\$" || fail "$want was not loaded — mapped: $(echo "$out" | grep -c '^mapped') objects"
done
echo "ok: 3. what it dlopens came from the medium: NSS (softokn3, freeblpriv3, nssckbi) and GTK's im-wayland among $(echo "$out" | grep -c '^mapped') mapped objects"
echo "all green (the medium carries a browser that runs)."
