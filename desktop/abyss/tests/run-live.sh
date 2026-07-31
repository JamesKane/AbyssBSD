#!/bin/sh
# AbyssBSD Swift DE — run every live mode, in order, and report.
#
# `live-sway.sh` proves one thing at a time and `live-session.sh` proves they
# compose; both are meant to be run by hand while working on the thing they
# test. This driver runs the whole set unattended and prints a pass/fail table,
# which is what you want in two situations: before a commit, and when bringing
# the harness up on a new platform (Phase 3, in the FreeBSD VM — see
# abyss/vm/build.sh for the build side).
#
# Usage:
#   abyss/tests/run-live.sh                  # every mode, PNGs to a temp dir
#   abyss/tests/run-live.sh -o /tmp/shots    # ... keeping the PNGs
#   abyss/tests/run-live.sh dock trash       # only modes whose label matches
#
# Each mode gets a timeout (ABYSS_LIVE_TIMEOUT, default 180s) so one hang can't
# stall the run. Exits non-zero if any mode failed.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

outdir=""
filters=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) outdir="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) filters="$filters $1"; shift ;;
  esac
done
if [ -z "$outdir" ]; then
  outdir=$(mktemp -d)
  keep=0
else
  mkdir -p "$outdir"
  keep=1
fi
: "${ABYSS_LIVE_TIMEOUT:=180}"

command -v sway >/dev/null || { echo "FAIL: sway not installed"; exit 1; }
command -v grim >/dev/null || { echo "FAIL: grim not installed"; exit 1; }
command -v timeout >/dev/null || { echo "FAIL: timeout(1) not found"; exit 1; }

# Build once here so a per-mode `swift build` is a no-op and a compile error
# fails the run immediately rather than 26 times.
echo "== swift build =="
swift build

# label:arguments to live-sway.sh. The label is what -filters match and what
# names the PNG; keep it short. Order runs cheap/foundational first so an early
# failure is the most informative one.
modes='
window:window
sysprefs:sysprefs
widgets:widgets
scroll:scroll
tabs:tabs
sheet:sheet
click:--click
type:--type
widgets-click:widgets --click
scroll-drag:scroll --click
menu:--menu
tabs-click:tabs --click
sheet-click:sheet --click
keys:widgets --keys
menu-keys:--menu --keys
hidpi:widgets --hidpi
wheel:scroll --wheel
repeat:window --repeat
wallpaper:wallpaper
reload:--reload
menubar:--menubar
menubar-keys:--menubar --keys
menubar-status:--menubar --status
dock:--dock
trash:--trash
finder:--finder
finder-keys:--finder --keys
spatial:--spatial
fileops:--fileops
desktop:--desktop
launch:--launch
'

want() {
  [ -z "$filters" ] && return 0
  for f in $filters; do
    case "$1" in *"$f"*) return 0 ;; esac
  done
  return 1
}

passed=0; failed=0; skipped=0; failed_labels=""
# Read the table a LINE at a time: several entries carry spaces ("widgets
# --click"), and a `for entry in $modes` would word-split those into separate
# bogus modes. The here-doc is on fd 3 so live-sway.sh keeps its own stdin, and
# it is not a pipeline, so the counters below stay in this shell.
while IFS= read -r entry <&3; do
  [ -n "$entry" ] || continue
  label=${entry%%:*}
  args=${entry#*:}
  if ! want "$label"; then skipped=$((skipped + 1)); continue; fi
  png="$outdir/$label.png"
  printf '%-14s ' "$label"
  # shellcheck disable=SC2086
  if timeout "$ABYSS_LIVE_TIMEOUT" sh abyss/tests/live-sway.sh $args "$png" \
       > "$outdir/$label.log" 2>&1; then
    printf 'ok\n'
    passed=$((passed + 1))
  else
    rc=$?
    printf 'FAIL (rc=%s)\n' "$rc"
    sed -n '$p' "$outdir/$label.log" | sed 's/^/               /'
    failed=$((failed + 1)); failed_labels="$failed_labels $label"
  fi
done 3<<EOF
$modes
EOF

# Two tests drive their own supervisor rather than AquaDemo: the shell session
# script, and the Swift supervisor that replaces it.
for extra in session anchor; do
  if ! want "$extra"; then skipped=$((skipped + 1)); continue; fi
  printf '%-14s ' "$extra"
  if timeout "$ABYSS_LIVE_TIMEOUT" sh "abyss/tests/live-$extra.sh" \
       "$outdir/$extra.png" > "$outdir/$extra.log" 2>&1; then
    printf 'ok\n'; passed=$((passed + 1))
  else
    rc=$?
    printf 'FAIL (rc=%s)\n' "$rc"
    sed -n '$p' "$outdir/$extra.log" | sed 's/^/               /'
    failed=$((failed + 1)); failed_labels="$failed_labels $extra"
  fi
done

echo
echo "passed=$passed failed=$failed skipped=$skipped"
[ "$keep" -eq 1 ] && echo "output in $outdir"
if [ "$failed" -ne 0 ]; then
  echo "failed:$failed_labels"
  echo "logs in $outdir/<label>.log"
  exit 1
fi
[ "$keep" -eq 1 ] || rm -rf "$outdir"
echo "all live modes green."
