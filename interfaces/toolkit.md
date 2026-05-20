# Toolkit — interface schema

> Concrete scriptable model exported by the **toolkit**. Shape: `DESIGN.md`
> §8. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Component** — the toolkit (`DESIGN.md` §8).
- **Realizes** — `DESIGN.md` §8, and §6.6 (scripting) made concrete.
- **Interface id** — none of its own; answers `scripting` (`scripting.md`).
- **Consumed by** — scripting tools, automation, and the latent
  accessibility substrate (decision #48).

The toolkit is a **library**, not a service — it is linked into every app
and the shell, never spawned as a component. Like the desktop shell
(`shell.md`) it **exports no bus interface of its own.** What it exports is
a *scriptable object model*: every app built on the toolkit answers the
scripting interface (`scripting.md`), and the toolkit defines the concrete
**suites** — `application`, `window`, `view` — that `scripting.md` leaves
abstract. This document is that model.

## What it consumes

- the **display protocol** (`display.md`) — each window is a display
  client; the toolkit submits frames and receives that window's input
  events (cooked, `input.md`) from the compositor. Window decorations are
  the compositor's, server-side (§7.4) — not the toolkit's.
- **settings** (`settings.md`) — the theme subtree; the toolkit themes
  widgets to the GNOME 2 appearance (§8).

## The scriptable object model

A holder of a scripting capability to an app drives it through three
nested suites. The `Specifier`/`SpecifierPath` types and the
`Introspect`/`Get`/`Set`/`Count`/`Invoke` messages are all `scripting.md`'s;
this is the concrete content they carry.

### Data types

- **`Rect`** — `{ x, y, width, height : i64 }`, in pixels.
- **`ViewKind`** — `enum`: `container`, `label`, `button`, `checkbox`,
  `text-field`, `list`, `scroll`, … — a view's widget kind.

### Suite `application` — the app root

The object a `Cap<Scripting>` to an app addresses.
```
property  name    : string            (read-only)
action    quit
children  window
```

### Suite `window`
```
property  title     : string
property  bounds    : Rect             (read-only — compositor-placed)
property  focused   : bool             (read-only)
property  minimized : bool
action    close
action    activate                     (raise and focus)
children  view                         (the root content view)
```
Window geometry is the compositor's (§7.4); a window resizes by a
`display.md` request, not a scripting `Set` — hence `bounds` is read-only.

### Suite `view`
```
property  kind     : ViewKind          (read-only)
property  bounds   : Rect              (read-only — layout-owned, §8)
property  visible  : bool
property  enabled  : bool
children  view                         (sub-views)
```
The `view` suite is the **generic** surface every view answers. A view's
*kind* extends it — `Introspect` reports the actual set:

- `button` — property `label : string`; action `invoke`.
- `checkbox` — property `checked : bool`.
- `text-field` — property `text : string`.
- `list` — `Count`-able `item` children; property `selection : i64`.

A tool discovers a kind's surface with `Introspect`; it never needs
compile-time knowledge of the widget set (§6.6).

## Addressing — specifier paths over `ViewId`s

Internally a view is a **`ViewId`** — a generational handle into the
window's per-window arena (`DESIGN.md` §8, decision #56). Externally a
script names it by `SpecifierPath` — *window "Save As" → view "ok"*. The
toolkit resolves the path to a `ViewId` and looks it up in the arena. Two
properties of the §8 model carry straight into scripting:

- The lookup is **generation-checked**. A `SpecifierPath` that named a view
  since destroyed resolves to no live `ViewId` and fails with
  `bad-specifier` — never the wrong widget.
- The arena is the window looper's private, share-nothing state
  (§6.10). A `SpecifierPath` is therefore always rooted at one window and
  cannot reach across windows — the addressing model and the ownership
  model agree.

## Capabilities

A `Cap<Scripting>` to an app's `application` root, carrying scripting
rights (`introspect`/`get`/`set`/`invoke`, `scripting.md`) and narrowable
to a subtree. The broker mints it per the app's manifest (decision #51); an
app handed none is simply not scriptable (`scripting.md`).

Layout- and compositor-owned properties — `view.bounds`, `view.kind`,
`window.bounds`, `window.focused` — are **read-only**: `Set` on one returns
`Error not-permitted` (detail `"read-only"`), independent of the
capability's rights.

## Errors

`scripting.md`'s `ErrorCode` applies unchanged. Toolkit-specific notes:
`bad-specifier` is what a stale or cross-window path yields (above);
`type-mismatch` a `Set`/`Invoke` with a wrong-typed value; `not-permitted`
covers both a rights failure and a read-only-property `Set`.

## Examples

**A tool clicks a button:**
```
→ Introspect  path=[ by-name "window" "Save As", direct "view",
                     by-name "view" "ok" ]
← Description { suites:["view","button"], properties:[{kind},{label},…],
                actions:[{invoke}], children:[] }
→ Invoke      path=[ by-name "window" "Save As", direct "view",
                     by-name "view" "ok", direct "invoke" ]
← Ack
```

**Rejected — a destroyed view:**
```
→ Get   path=[ by-name "window" "Save As", direct "view",
               by-name "view" "ok", direct "label" ]
← Error code=bad-specifier detail="no live view \"ok\" — window closed"
```
