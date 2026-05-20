# Desktop shell — interface schema

> Concrete message schema for the **desktop shell**. Shape: `DESIGN.md`
> §11.10. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Component** — the desktop shell (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §11.10.
- **Interface id** — none of its own.

The desktop shell **exports no interface of its own.** It is a *consumer* —
its substance is what it presents and what it consumes (`DESIGN.md` §11.10).
Like any app it answers the **scripting interface** (`scripting.md`) — that
is its only exported surface, and it is what lets a scripting tool drive the
panel, menu, and window list. Nothing in the system depends on the shell; it
is a leaf.

## What it consumes

The shell holds capabilities to:

- the **display protocol** (`display.md`) — through a *shell-scoped*
  `Cap<Display>` granting the shell-only messages (`ListWindows`,
  `ActivateWindow`, `ReserveStrut`) an app's capability does not;
- **settings** (`settings.md`) — its configuration;
- **notification** (`notification.md`) — it subscribes to the active set and
  renders the popups and notification centre;
- **power** (`power.md`) — the battery indicator and the shutdown / lock
  controls;
- **device-monitor** (`device-monitor.md`) — removable-media events, and
  `Mount` on user action;
- **networking** (`networking.md`) and **audio** (`audio.md`) — the network
  and volume indicators, and their controls.

It launches apps through the **broker** (`broker.md`, `Spawn`).

## Why this document exists

For completeness: every component in the map (`DESIGN.md` §11.1) has an
interface document. The shell's records that it exports nothing — itself a
design statement (§11.10): the shell is furniture and a consumer, never a
dependency.
