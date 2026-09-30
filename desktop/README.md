# AbyssBSD

A FreeBSD fork with a desktop environment written in **Swift 6**, styled as a
faithful **Mac OS X 10.2 "Jaguar" Aqua** clone, running on **Wayland**.

> This is the monorepo's `desktop/`. The earlier Rust DE (checked out beside the
> monorepo as `AbyssBSD-old`) is the **design source we rewrite from**: its compositor (`tide`), brokerless IPC (`current`) and config (`pool`)
> are reference implementations to read, not components to link. Everything ships
> in Swift, dropping to C only where Swift can't reach — system libraries and
> their shims.

![first window](docs/screenshots/first-window.png)

## Build & run (Linux dev box)

```sh
swift build && swift test

# Headless visual check (no compositor needed):
AQUA_RENDER_PNG=/tmp/aqua.png AQUA_SCALE=2 .build/debug/AquaDemo

# Live, against a running wlroots compositor (install sway/labwc first):
.build/debug/AquaDemo

# The whole desktop — a nested compositor plus the desktop, menu bar and Dock:
abyss/session.sh
```

Or the whole loop: `sh abyss/tests/run.sh`.

![the Aqua session](docs/screenshots/live-session.png)

## Layout

| Path | What |
|------|------|
| `de/cwayland` | C interop: libwayland-client + xdg-shell + Swift-callable shim |
| `de/ccairo` | system cairo (software 2D backend) |
| `de/surface` | `Surface` — Wayland client runtime |
| `de/aqua` | `Aqua` — the Jaguar toolkit (theme, drawing, widgets) |
| `de/aquademo` | the runnable demo |
| `abyss/session.sh` | the dev session launcher — one command boots the desktop |
| `abyss/vm`, `abyss/tests` | FreeBSD build/test VM harness (borrowed + adapted) |
| `docs/` | [PLAN.md](docs/PLAN.md), [STATUS.md](docs/STATUS.md), [PHASE2.md](docs/PHASE2.md), [PHASE3.md](docs/PHASE3.md), [SWIFT-ON-FREEBSD.md](docs/SWIFT-ON-FREEBSD.md) |

See [docs/PLAN.md](docs/PLAN.md) for the full phased roadmap,
[docs/STATUS.md](docs/STATUS.md) to resume work, and
[docs/HANDOFF.md](docs/HANDOFF.md) for lessons learned + the traps to avoid.
