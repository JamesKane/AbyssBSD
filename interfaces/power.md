# Power & lifecycle — interface schema

> Concrete message schema for the **power & lifecycle interface**. Shape:
> `DESIGN.md` §11.8. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — the power & lifecycle service (`DESIGN.md` §11.1).
- **Realizes** — `DESIGN.md` §11.8.
- **Consumed by** — the desktop shell (battery indicator, control), the
  compositor (suspend / lock events), the session lock (`LockNow`), and apps
  (inhibitors).
- **Interface id** — `power`.

## Data types

- **`PowerSource`** — `enum { ac, battery }`.
- **`Battery`** — `{ level : f64 (0–1), charging : bool, estimate : i64? (s) }`.
- **`InhibitKind`** — `enum { suspend, idle, lock }`.
- **`State`** — `{ source : PowerSource, battery : Battery, locked : bool }`.

## Messages — consumer → power service

```
Subscribe — request (retained)   → State | Error
```
`State` is the snapshot; the retained capability then receives the events
below.

```
RequestSuspend / RequestHibernate / RequestShutdown
RequestReboot / RequestLock      — request   → Ack | Error
```
Each is capability-gated (see *Capabilities*). Outstanding **block**
inhibitors refuse the action; **delay** inhibitors postpone it through a
bounded prepare window.

```
Inhibit — request (retained)
  kind   : InhibitKind
  mode   : enum { block, delay }
  reason : string
  → InhibitToken | Error
```
The reply is a **capability**. The inhibit holds for exactly as long as the
holder keeps it; dropping it — or the holder exiting — lifts the inhibit
(`README.md`, lifetime). There is no `Uninhibit` message: the capability
*is* the inhibitor.

## Messages — power service → subscriber

```
Suspending / Resumed          — event
BatteryChanged                — event   battery : Battery
PowerSourceChanged            — event   source  : PowerSource
LowBattery / CriticalBattery  — event
IdleEntered / ActiveResumed   — event
LockNow / Unlocked            — event
ShuttingDown                  — event   action : enum { shutdown, reboot }
```

The session lock presents its surface on `LockNow` (§11.11); the compositor
releases the display on `Suspending` and reacquires on `Resumed`; the shell
draws the battery indicator from `BatteryChanged` / `PowerSourceChanged`.

## Capabilities

A `Cap<Power>` carries which control requests it permits. Typical grants:

- the **shell** — `RequestShutdown` / `Reboot` / `Lock`, plus `Subscribe`;
- an **app** — `Inhibit` and `Subscribe`, but no `Request*` control;
- the **compositor** and **session lock** — `Subscribe` only.

A `Request*` outside the capability's grant is `not-permitted`.

## Errors

`ErrorCode`: `not-permitted` (a control request the capability does not
grant); `blocked` (a `Request*` refused by an outstanding block inhibitor —
its `reason` may be surfaced to the user).

## Examples

**A media player inhibits idle while playing:**
```
→ Inhibit  kind=idle  mode=block  reason="playing video"
← InhibitToken <cap>
…  the player holds the capability; the screen never idles  …
…  playback ends — the player drops the capability  →  idle timing resumes
…  the player crashes instead — the capability closes — same result
```

**Lock on idle:**
```
power service → subscribers:  IdleEntered        (idle timeout reached)
power service → subscribers:  LockNow
session lock: presents the unlock surface (§11.11)
```
