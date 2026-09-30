#!/bin/sh
# AbyssBSD Swift DE — the frame contract, gated (PHASE6.md P6.1; DESKTOP.md §0).
#
# "We don't claim the frame budget — we fail CI when we miss it." (C5)
#
# Two benches, neither of which needs a compositor, a GPU, or a display — which
# is the point of doing the contract before the pixels:
#
#   C1 (cadence)  the metronome holds its period and the composite fits the
#                 budget. Asserted as a p99, never a max: one outlier in a VM
#                 proves nothing (PHASE6.md §6).
#   C2's floor    the present loop allocates ZERO times. An allocation on the
#                 present path is a lock a client can contend, which is exactly
#                 what C2 forbids (PLAN.md risk 4).
#
# Usage: abyss/tests/bench-metronome.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

bin="$root/.build/debug/undertow"
[ -x "$bin" ] || swift build

# The composite budget. DESKTOP.md's C1 is 2 ms p99 for the compositor's own
# per-frame CPU work; we assert against that number and not a softer one.
BUDGET_US=2000

# 240Hz keeps the bench under 3 seconds while still exercising a tighter period
# than any display we target. Frame count is a compromise: enough for the
# percentile to mean something, few enough to re-run when it flakes.
HZ=240
FRAMES=600
SURFACES=512

# The miss budget, and why it is not zero.
#
# C1's target is "zero missed flips at p99.9" — but that is a claim about a
# present thread running at REAL-TIME PRIORITY, and this one is not: rtprio
# needs the `allow.rtprio` jail param, which is Phase 4 work on metal. Measured
# here over eight runs, 240Hz/600 frames gives 0 misses seven times and 1 once:
# rare OS wake-latency outliers, not a defect.
#
# So the gate is a RATE, stated per mille, rather than a zero that would flake
# roughly one run in eight — and a gate that flakes is a gate people learn to
# ignore. 5 per mille (3 frames of 600) sits an order of magnitude above the
# observed noise and an order of magnitude below every real regression this
# bench has actually caught: the margin runaway produced ~30 per mille, and a
# margin that ignored wake latency produced ~25.
#
# **Zero-at-p99.9 becomes assertable in Phase 4, with rtprio.** Until then this
# is the honest approximation, and it says so rather than quietly redefining C1.
MISS_BUDGET_PERMILLE=5

echo "== C1: cadence and composite budget =="
"$bin" bench-metronome --hz "$HZ" --frames "$FRAMES" --surfaces "$SURFACES" \
       --assert-missed-permille "$MISS_BUDGET_PERMILLE" \
       --assert-cost-p99-us "$BUDGET_US" \
  || { echo "FAIL: the frame contract regressed"; exit 1; }

echo
echo "== C2's precondition: an allocation-free present path =="
# The bench refuses to report anything unless its positive control fires first:
# a blind probe reports a comfortable zero, which is indistinguishable from
# success and is how this measurement was wrong the first time (HANDOFF §2.37).
"$bin" bench-alloc --frames 5000 --surfaces "$SURFACES" \
  || { echo "FAIL: the present loop allocates"; exit 1; }

echo
echo "== the wlroots bridge: real frames on a real backend =="
# P6.2. The synthetic bench above proves the SCHEDULER; this proves the BRIDGE —
# buffers allocated, render passes submitted, commits landed, and present events
# coming back to feed the predictor. The two assertions that matter are inside
# the binary and are not about speed at all: no present events means we
# committed frames that never landed, and no predictor samples means flip
# feedback is not reaching the scheduler. Either one is a broken compositor that
# would otherwise look perfectly healthy.
"$bin" headless --hz 60 --frames 120 --surfaces 128 --width 800 --height 600 \
       --assert-missed-permille "$MISS_BUDGET_PERMILLE" \
       --assert-cost-p99-us "$BUDGET_US" \
  || { echo "FAIL: the wlroots bridge regressed"; exit 1; }

echo
echo "all green (the frame contract holds)."
