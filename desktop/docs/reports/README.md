# The hardware matrix, one report per row

`fathom --save` writes a report to the live medium's ESP; this directory is where
returned reports are kept. **The matrix is a deliverable, not a side effect**
(PRODUCT.md §4.5) — we cannot buy every machine, so the medium is the instrument
and every person who tries AbyssBSD is a data point.

What a report may contain is decided on the way in rather than redacted on the
way out (PHASE12 §6.2): kinds of hardware, never identity. No serials, MAC
addresses, IP addresses, hostname, pool names or mount points.

| Machine | GPU | Boot | Frame contract | Report |
|---|---|---|---|---|
| MSI MS-7D25, i7-12700KF | RX 6750 XT (amdgpu, Navi 22) | UEFI | **58/300 missed @ 60 Hz** — does not hold (PHASE4 §5.7) | [MS-7D25](fathom-micro-star-international-co-ltd-ms-7d25.txt) |
| Radxa Dragon Q8B, Snapdragon 8cx Gen 3 (SC8280XP) | Adreno 690 (msm + msmfb, board port) | UEFI (ACPI) | **0–5/300 missed @ 60 Hz**, composite p99 ~20 µs; one late flip event per run (2026-10-01, [bench note](q8b-bench-2026-10-01.md)) | [Q8B](fathom-radxa-computer-co-ltd-radxa-dragon-q8b.txt) |

Consuming these into a published support matrix is **not** Phase 12's job
(§6.3) — it needs somewhere to send them, a format that survives version skew,
and someone to curate it, all of which is Phase 17's kind of obligation. This
directory is the evidence, kept because it is the first of it.
