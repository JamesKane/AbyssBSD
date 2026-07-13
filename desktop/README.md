# AbyssBSD

A FreeBSD fork with a desktop environment written in **Swift 6**, styled as a
faithful **Mac OS X 10.2 "Jaguar" Aqua** clone, running on **Wayland**.

> Sibling project `../AbyssBSD` (a Rust DE) is the design source and supplies the
> engine components (compositor `tide`, brokerless IPC `current`, config `pool`)
> that this project reuses while the Aqua shell + toolkit are built in Swift.

![first window](docs/screenshots/first-window.png)

## Build & run (Linux dev box)

```sh
swift build && swift test

# Headless visual check (no compositor needed):
AQUA_RENDER_PNG=/tmp/aqua.png AQUA_SCALE=2 .build/debug/AquaDemo

# Live, against a running wlroots compositor (install sway/labwc first):
.build/debug/AquaDemo
```

Or the whole loop: `sh abyss/tests/run.sh`.

## Layout

| Path | What |
|------|------|
| `de/cwayland` | C interop: libwayland-client + xdg-shell + Swift-callable shim |
| `de/ccairo` | system cairo (software 2D backend) |
| `de/surface` | `Surface` — Wayland client runtime |
| `de/aqua` | `Aqua` — the Jaguar toolkit (theme, drawing, widgets) |
| `de/aquademo` | the runnable demo |
| `abyss/vm`, `abyss/tests` | FreeBSD build/test VM harness (borrowed + adapted) |
| `docs/` | [PLAN.md](docs/PLAN.md), [STATUS.md](docs/STATUS.md), [SWIFT-ON-FREEBSD.md](docs/SWIFT-ON-FREEBSD.md) |

See [docs/PLAN.md](docs/PLAN.md) for the full phased roadmap,
[docs/STATUS.md](docs/STATUS.md) to resume work, and
[docs/HANDOFF.md](docs/HANDOFF.md) for lessons learned + the traps to avoid.
