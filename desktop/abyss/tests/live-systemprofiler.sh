#!/bin/sh
# AbyssBSD Swift DE — System Profiler: what this computer is, fastfetch's
# report in a window.
#
# The app under our compositor, read against the machine itself. Claims:
#
#   1. it maps and reads every row: each fact is a value or an honest
#      "unknown", never left out (19 rows);
#   2. (FreeBSD) the facts agree with the machine: the kernel's release, the
#      CPU's model and count, the package count, memory's total, the root
#      filesystem's type, the address — each against what the base's own
#      tools say;
#   3. Copy (a click) offers fastfetch's text as the clipboard, and the
#      compositor takes it under the click's serial;
#   4. (Linux) a machine with no sysctl shows its uname and says unknown for
#      what it cannot ask, rather than inventing it.
#
# Usage: abyss/tests/live-systemprofiler.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

bin="$root/.build/debug"
for b in undertow AquaDemo; do [ -x "$bin/$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-sysprof.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${app:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; grep 'System Profiler' "$work/app.log" 2>/dev/null | tail -3 | sed 's/^/  app| /'; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt 1 ] && [ $i -lt 150 ]; do i=$((i + 1)); sleep 0.1; done
          [ "$(count "$2" "$1")" -ge 1 ] || fail "$3"; }
fact() { grep 'System Profiler: facts' "$work/app.log" | tail -1 | sed 's/^[^:]*: facts [0-9]*: //' | tr '|' '\n' \
           | sed 's/^ *//; s/ *$//' | awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'; }

wayland-scanner client-header "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"

"$bin/undertow" run --frames 0 --width 1024 --height 768 --socket "abyss-sp-$$" --config-dir "$work" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/abyss-sp-$$" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
export WAYLAND_DISPLAY="abyss-sp-$$"
AQUA_SCENE=systemprofiler ABYSS_CONFIG_DIR="$work" "$bin/AquaDemo" > "$work/app.out" 2> "$work/app.log" & app=$!
await "$work/app.log" 'System Profiler: buttons' "System Profiler never drew"

# ------------------------------------------------------------ 1. every row
n=$(grep 'System Profiler: facts' "$work/app.log" | tail -1 | sed 's/.*facts \([0-9]*\):.*/\1/')
[ "$n" = 19 ] || fail "System Profiler has $n rows, not 19"
for label in OS Kernel Uptime Packages Shell Desktop "Window Manager" Theme Terminal Locale \
             Host CPU GPU Memory Swap "Disk (/)" Display "Local IP" Battery; do
  [ -n "$(fact "$label")" ] || fail "the row $label is missing"
done
echo "ok: 1. all 19 rows, each a value or an honest unknown"

if [ "$(uname -s)" = FreeBSD ]; then
  # ---------------------------------------------------------- 2. against the machine
  case "$(fact Kernel)" in *"$(sysctl -n kern.osrelease)") ;; *) fail "Kernel: $(fact Kernel)" ;; esac
  model=$(sysctl -n hw.model | sed 's/ *$//')
  [ "$(fact CPU)" = "$model ($(sysctl -n hw.ncpu))" ] || \
    case "$(fact CPU)" in "$model ($(sysctl -n hw.ncpu)) @ "*) ;; *) fail "CPU: $(fact CPU) vs $model" ;; esac
  [ "$(fact Packages)" = "$(pkg info -q | wc -l | tr -d ' ') (pkg)" ] || fail "Packages: $(fact Packages)"
  total=$(( $(sysctl -n hw.pagesize) * $(sysctl -n vm.stats.vm.v_page_count) ))
  gib=$(echo "$total" | awk '{ printf "%.2f GiB", $1 / 1073741824 }')
  case "$(fact Memory)" in *"/ $gib ("*) ;; *) fail "Memory: $(fact Memory), the machine has $gib" ;; esac
  fs=$(df -T / | tail -1 | awk '{print $2}')
  case "$(fact 'Disk (/)')" in *" - $fs") ;; *) fail "Disk: $(fact 'Disk (/)') — / is $fs" ;; esac
  ip=$(fact 'Local IP' | cut -d/ -f1)
  ifconfig | grep -q "inet $ip " || fail "Local IP $ip is not this machine's"
  echo "ok: 2. kernel, CPU ($model), $(fact Packages), memory ($gib), $fs on /, and $ip — as the base's tools say"
else
  # ---------------------------------------------------------- 4. no sysctl here
  case "$(fact OS)" in *Linux*) ;; *) fail "OS on Linux: $(fact OS)" ;; esac
  [ "$(fact CPU)" = unknown ] || fail "with no sysctl, CPU should be unknown, not '$(fact CPU)'"
  echo "ok: 4. $(uname -s): its uname shown ($(fact OS)), and unknown for what it cannot ask"
fi

# ------------------------------------------------------------ 3. Copy
geom=""; i=0
while [ -z "$geom" ] && [ $i -lt 100 ]; do
  geom=$(grep '^window org.abyssbsd.systemprofiler' "$work/ut.out" | tail -1 | awk '{print $(NF-1)}'); sleep 0.05; i=$((i + 1))
done
[ -n "$geom" ] || fail "undertow never reported the window"
at=$(grep 'System Profiler: buttons' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n 's/^copy=//p')
mkfifo "$work/vp"
"$work/vpointer" 1024 768 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
await "$work/vp.log" ready "vpointer never bound"
printf 'm %s %s\np\nr\n' $(( ${geom%,*} + ${at%,*} )) $(( ${geom#*,} + ${at#*,} )) >&3
await "$work/app.log" 'System Profiler: copied' "Copy did not copy"
# The compositor took the offer — the click's serial was good — and the
# report was offered whole. (Reading it back needs a client with keyboard
# focus: a surfaceless `abyssclip paste` is never sent a selection, by the
# protocol — live-clipboard.sh's own note. The text is SystemFactsTests'.)
i=0; while ! grep -q '^selections-accepted=1' "$work/ut.out" && [ $i -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
grep -q '^selections-accepted=1' "$work/ut.out" || fail "the compositor did not take the clipboard offer"
bytes=$(grep 'System Profiler: copied' "$work/app.log" | tail -1 | sed 's/.*copied \([0-9]*\) bytes.*/\1/')
[ "$bytes" -gt 300 ] || fail "Copy offered only $bytes bytes"
echo "ok: 3. Copy: the compositor took the offer under the click's serial — the report, $bytes bytes"
echo "all green (System Profiler says what this computer is, as the machine says it, and copies it)."
