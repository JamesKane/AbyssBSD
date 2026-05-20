# AbyssBSD

*A desktop operating system that fits in your head.*

## The 40-million-line problem

A modern desktop is an act of forgetting. Boot one and you are running tens
of millions of lines of code — kernel, display server, message bus, policy
daemons, portal services, toolkit upon toolkit — that no single person has
read, that nobody fully understands, and that grows by accretion every
release. The hardware underneath got a thousand times faster since 1995.
The desktop did not get faster. It got *heavier*. Every gain was spent on
layers.

This is not a law of nature. It is a habit. AbyssBSD is the refusal of that
habit.

## What AbyssBSD is

AbyssBSD is an opinionated desktop OS built on the **FreeBSD base** —
kernel, libc, drivers, toolchain, and ports kept whole and tracked
upstream, never forked. FreeBSD does the unglamorous 90%, and does it well.
On top of that base, AbyssBSD adds one coherent thing: a desktop with a
genuinely new architecture.

The feel is **BeOS** — snappy, message-driven, never stalling. The look is
**GNOME 2** — clean, conventional, familiar. The novelty is entirely in the
architecture beneath, not the chrome.

## The ideas

- **One message primitive.** A single typed message carries UI events,
  inter-thread traffic, and IPC alike. It *is* the bus. There is no D-Bus,
  no second mechanism.
- **Capabilities, not ambient authority.** A process is born holding
  nothing; authority travels only as unforgeable handles in messages,
  backed by FreeBSD's native Capsicum and jails. Security is not bolted on
  beside the bus — it *is* the bus.
- **One thing well, replaceable at the seam.** Every component does one job
  behind an enforced message interface. Coherent like macOS — but every
  part swappable.
- **A from-scratch compositor and toolkit.** Wayland-free, retained-mode,
  server-side decorations, direct scanout for games.
- **Zero vendored dependencies.** The AbyssBSD layer leans on the Rust
  standard library and a tiny, version-controlled allowlist. Every
  dependency is a deliberate decision.
- **Budgets are walls.** The idle desktop is budgeted at ~256 MB at 4K.
  Input-to-photon adds at most one refresh interval. These are enforced —
  exceeding one is a build failure, not a regret logged for later.

## Written in Rust

The whole AbyssBSD layer — bus, broker, compositor, toolkit, shell, apps —
is written in **Rust**: memory safety without a garbage collector,
compiler-checked concurrency, a mature toolchain with no runtime to wait
on. No GC pauses anywhere in the resident set.

## The wager

A 12-core, 5 GHz machine should never feel slower than a 1995 desktop did.
That it routinely does is accreted latency — and accreted latency can be
designed out. AbyssBSD is small enough to hold in one head, fast because it
was measured, and secure because authority is explicit.

A return to simplicity. By construction.

---

*Status: design captured. Nothing built yet — see [`docs/DESIGN.md`](docs/DESIGN.md).*
