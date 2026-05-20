# Scripting — interface schema

> Concrete message schema for the **scripting interface**. Shape: `DESIGN.md`
> §6.6. Conventions: `interfaces/README.md`. Status: draft.

## Interface

- **Exported by** — *every scriptable handler* (`DESIGN.md` §6.6). This is
  not one component's interface but a **cross-cutting suite**: every
  component and app, and every object within one (a window, a view),
  answers it.
- **Realizes** — `DESIGN.md` §6.6.
- **Consumed by** — scripting tools (a `hey`-equivalent), automation, and —
  latently — accessibility tooling (the substrate, though no a11y stack is
  built).
- **Interface id** — `scripting`.

Following BeOS: a handler exposes named **properties** and **actions**,
grouped into **suites** and addressed through a **specifier path**. A holder
of a scripting capability to an object can discover and drive it with no
compile-time knowledge of it — this is what the self-describing message
payload (§6.3) is *for*.

## Data types

- **`Specifier`** — addresses *which* thing: `direct{ name }`,
  `index{ name, i }`, `by-name{ name, key }`, `range{ name, from, to }`.
- **`SpecifierPath`** — a list of `Specifier`, navigating from the target
  handler inward — e.g. *window "Editor" → view "canvas" → property
  "colour"*.
- **`Description`** — what `Introspect` returns: the handler's suites, each
  property's name and type, each action's name and signature, and the
  navigable sub-objects.
- **`Value`** — a §6.3 typed value.

## Messages — client → any scriptable handler

```
Introspect — request   path : SpecifierPath                  → Description | Error
Get        — request   path : SpecifierPath                  → Value | Error
Set        — request   path : SpecifierPath   value : Value   → Ack | Error
Count      — request   path : SpecifierPath                  → i64 | Error
Invoke     — request   path : SpecifierPath   args : dict     → Value | Error
```

`Introspect` discovers a handler — without it a tool knows nothing, with it
everything. `Get` / `Set` read and write a property; `Count` returns the
size of an indexable property so a tool can iterate; `Invoke` runs a named
action. Every message addresses its target by `SpecifierPath`, so a tool
reaches a deeply nested object — *the colour of the canvas view of the
window named "Editor"* — in a single message.

## Capabilities

A `Cap<Scripting>` to an object carries **rights** (the §10 model):
`introspect`, `get`, `set`, `invoke` — narrowable. An *inspect-only*
scripting capability admits `Introspect` / `Get` / `Count` but not `Set` /
`Invoke`; a *full* one admits all. A tool is handed exactly the rights its
task needs, scoped to a subtree of the object graph it cannot reach beyond.

Scripting authority *is* capability authority — there is no separate
permission check. A handler answers any scripting message it receives,
because holding the capability, with the right, *is* the permission. (It
follows that components handed no scripting capability are simply not
scriptable — see `session-lock.md`.)

## Errors

`ErrorCode`: `no-such-property` (the `SpecifierPath` names nothing);
`no-such-action`; `bad-specifier` (e.g. an `index` past the end);
`type-mismatch` (`Set` / `Invoke` with a wrong-typed value); `not-permitted`
(the capability lacks the right — `Set` on an inspect-only capability).

## Examples

**A tool inspects, then drives, an app:**
```
→ Introspect  path=[ direct "window" ]
← Description { suites:["window"], properties:[{title:string}, …],
                actions:[{close}], children:["view"] }
→ Get   path=[ direct "window", direct "title" ]
← Value "Untitled"
→ Set   path=[ direct "window", direct "title" ]   value="Report.txt"
← Ack
```

**Rejected — an inspect-only capability:**
```
→ Set   path=[ direct "window", direct "title" ]   value="x"
← Error code=not-permitted detail="capability grants introspect/get only"
```
