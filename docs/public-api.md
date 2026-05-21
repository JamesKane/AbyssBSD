# Public API register

The **public surface**: the interfaces that out-of-tree code, meaning
third-party applications and scripts, is permitted to depend on. The policy
that governs how this surface may change is `design/api-evolution.md`.

This register is the boundary itself, not a description of it. **An item
listed here is public and epoch-governed. An item not listed here is
internal, and may be broken in a single atomic commit with no deprecation
window** (`design/api-evolution.md` §3). When an interface or API becomes
something an app may rely on, it is added here in the same change; until
then it is internal by default.

This is not the tech-debt list (`TECH-DEBT.md`) or the acceleration
register (`acceleration.md`). It is the standing definition of what
AbyssBSD has promised to applications.

---

## Status vocabulary

Each item is in exactly one state (`design/api-evolution.md` §6):

- **pre-epoch** — designated public, but no epoch is frozen yet. The item
  is still fluid and may change freely. This is the state of the entire
  surface before the first public release (§12).
- **live (epoch N)** — frozen as of epoch N. Additive change is free
  (§5); subtractive change requires deprecation.
- **deprecated (removed in epoch N)** — scheduled for removal; a migration
  ships with the deprecation. CI fails the build once epoch N is current
  and the item still exists (§7).

The **current epoch** is a workspace constant read by `cargo xtask ci` and
by the broker. No epoch is frozen yet: **epoch 1 is the surface of the
first public release.**

---

## The surface

Four groups make up the public surface. Everything else, including the
input, device-monitor, networking, audio-control, session-lock, and broker
protocols, and every crate-to-crate Rust API, is internal.

### 1. Toolkit API

The Rust API third-party applications link against.

| Item | Where | Status |
|---|---|---|
| Interface Kit — widgets, layout, theming, the view hierarchy | `abyss-toolkit` | pre-epoch |
| Application Kit — app lifecycle, the looper/handler model, messaging | `abyss-toolkit` | pre-epoch |
| The arena / `ViewId` view model | `abyss-toolkit` | pre-epoch |

Storage Kit and Media Kit are post-v1 (`DESIGN.md` §8) and join this group
when they exist.

### 2. Scripting interface

The surface every handler exposes, and that scripts consume.

| Item | Where | Status |
|---|---|---|
| The introspect / get / set / invoke suite | `interfaces/scripting.md` | pre-epoch |
| The Lua scripting surface | `interfaces/scripting.md` | pre-epoch |

Introspection is generated from the live typed interfaces, so a removed
field is absent from introspection and a script touching it gets a clean
runtime error (`design/api-evolution.md` §10).

### 3. App bundle manifest

The format an application bundle declares itself with.

| Item | Where | Status |
|---|---|---|
| The bundle manifest format | `DESIGN.md` §11.14; Gate D `design/broker-and-transport.md` | pre-epoch |
| The manifest `epoch` field | Gate D `design/broker-and-transport.md` | pre-epoch |

### 4. App-facing message interfaces

The message interfaces an application speaks directly. The toolkit speaks
some of these on an app's behalf; an app may also speak them itself, and a
non-toolkit app such as a game speaks the display protocol directly.

| Interface | Where | Status |
|---|---|---|
| Display protocol | `interfaces/display.md` | pre-epoch |
| Notification | `interfaces/notification.md` | pre-epoch |
| Settings (an app's own subtree) | `interfaces/settings.md` | pre-epoch |
| Power inhibitors (the app-facing subset) | `interfaces/power.md` | pre-epoch |

The internal vs. app-facing split for each interface is provisional until
v1; an interface's doc is the source of truth for which of its messages an
app may send, and this register is reconciled with it as the schemas are
finalized at Gates F and H.

---

## Deprecations in flight

None. No epoch is frozen, so nothing can yet be deprecated.

When the first removal is scheduled, it is listed here with its item, the
epoch that removes it, and a pointer to the migration that ships with it
(`design/api-evolution.md` §6).
