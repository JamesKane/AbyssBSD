# API evolution policy

> Design elaboration: how AbyssBSD's API surface is allowed to change over
> the years, and how detritus is prevented from accumulating on it. This is
> a cross-cutting policy doc, not a single gate's deliverable. It governs
> every gate that fixes a public interface, notably Gate C (the toolkit
> API) and Gate D (the bundle manifest schema), and it constrains every
> `interfaces/*.md` schema.
>
> Companion register: `../public-api.md` lists what the public surface
> actually contains.
>
> Status: draft.

---

## 1. The problem this exists to prevent

A mature POSIX system carries decades of API it can no longer remove. The
cost is not the dead functions themselves; it is *combinatorial*. POSIX
exposes several independently-selectable axes at once: feature-test macros
(`_POSIX_C_SOURCE`, `_XOPEN_SOURCE`, `_GNU_SOURCE`), libc versions each
supporting every prior one, per-symbol versioning (`GLIBC_2.34` and every
ancestor in one `.so`), optional extensions, per-platform variation. The
surface any consumer must be tested against is the *product* of those axes,
and because nothing is ever removed, the product only grows. `gets()`
survives not for a technical reason but because no axis ever scheduled its
death.

AbyssBSD refuses this the way it refuses the rest of the 40-million-line
desktop (`DESIGN.md` §1): by construction, not by good intentions. A policy
that prevents the combinatorial blow-up needs exactly two commitments,
**make the axes non-independent** and **make removal mandatory**, and a
mechanism behind each.

## 2. The closed-world dividend

The AbyssBSD layer is **curated, tested, and versioned together as one**
(`DESIGN.md` §11.3), and the broker wires a **statically-auditable
authority graph** (`DESIGN.md` §11.9): every component, and every edge
between components, is known in-tree.

That is the structural fact POSIX lacks. libc cannot remove anything
because its consumers are anonymous and uncountable. AbyssBSD's *internal*
interfaces have a producer and a consumer set that are both in this
repository. A breaking change to one of them is a single atomic commit, not
a negotiation with the world.

The policy spends all of its machinery on the one place this dividend does
*not* apply, the surface that out-of-tree code depends on, and explicitly
frees everything else.

## 3. Two surfaces

Every interface in AbyssBSD is exactly one of two kinds.

**Internal surface.** Interfaces with only in-tree consumers: most of
`interfaces/*.md` (input, device-monitor, power, the broker's own protocol,
audio control, networking), every crate-to-crate Rust API, the wire format
internals. An internal interface carries **no compatibility guarantee and
no deprecation window**. A breaking change updates the producer, every
consumer, and the golden vectors in one commit. The per-interface `version`
field on these (`interfaces/README.md`) is a build-coherence check against
a botched mixed-binary upgrade, not a compatibility surface. Nobody should
version an internal interface defensively "just in case"; there is no case.

**Public surface.** Interfaces that out-of-tree code, meaning third-party
applications and scripts, is permitted to depend on. It is small and
enumerable: the **toolkit API** (`abyss-toolkit`, the Interface and
Application Kits), the **scripting interface** (`interfaces/scripting.md`
and the Lua surface), the **app bundle manifest format**, and the
**app-facing message interfaces** (the display protocol, notification,
settings, session-lock as an app sees them).

The boundary is not a matter of judgement at each change. It is a register:
**`public-api.md` lists the public surface, item by item. If an item is not
in that register, it is internal, and breakable.**

## 4. One epoch

The public surface has exactly **one version axis**: a single integer, the
**epoch**, covering the whole surface at once. Rust calls the same idea an
edition.

There is no finer granularity. There are no per-interface public versions,
no feature macros, no optional public extensions. An application cannot
request "settings epoch 3 with toolkit epoch 1." The public surface advances
as one unit, so the consumer's exposure is an *ordered list* of epochs, never
a matrix. This is the move from section 1 that makes the axes
non-independent: there is only one axis, so there is no product.

An application's bundle manifest declares the single epoch it was built
against (section 8). The current epoch is a workspace constant; CI and the
broker both read it.

Epochs are cut **event-driven, not on a calendar**. An epoch boundary
exists when, and only when, a removal needs to take effect (section 6).
A release with nothing to remove does not advance the epoch. This keeps
epochs rare, and keeps an epoch number meaningful: it marks a real
subtraction from the surface.

## 5. Additive change is free

Adding to the public surface does **not** advance the epoch.

The wire format already makes additive change safe in both directions: a
`#[derive(Wire)]` struct ignores unknown dict entries on decode, and treats
a missing `Option` field as `None` (`design/wire-format.md` §7). A newer
sender and an older receiver interoperate with no version negotiation. A new
optional message field, a new message, a new interface, a new toolkit widget,
a new scripting verb: all are free, at any time, within the current epoch.

The epoch bump is reserved strictly for change that is **not** additive:
removing a field or message, renaming one, changing a type, or changing the
*meaning* of something whose shape is unchanged. If a change can break a
correct consumer built against the previous epoch, it is subtractive and
belongs in section 6. If it cannot, it is additive and ships now.

## 6. Subtractive change: deprecate, schedule, migrate

Removing anything from the public surface is a three-part obligation, and
all three parts land **in the same commit** as the deprecation.

1. **Deprecate.** The item is marked deprecated: `#[deprecated]` for toolkit
   and crate APIs, a `deprecated` status in `public-api.md` for message
   interfaces and the scripting and manifest surfaces.

2. **Schedule the removal.** The deprecation records the epoch that removes
   the item. Not "deprecated"; "deprecated, removed in epoch N+1." The
   removal date is a commitment made at deprecation time. POSIX never sets
   the date, so the date never arrives; here the date is part of the
   deprecation or the deprecation is rejected.

3. **Ship the migration.** The same commit lands the mechanical migration
   off the item: a `cargo fix`-style rewriter for a toolkit API, a codemod
   for a scripting change, a transcoder for a message-schema change. An item
   may not be deprecated without the migration that carries consumers past
   it. Removal is politically possible only when it is cheap for the
   consumer; an unowned migration is why `gets()` is immortal.

A public item lives in exactly one of three states: **live**, **deprecated
(removed in epoch N)**, or gone. There is no fourth, indefinite state.

## 7. The wall

Deprecation without enforced removal is just a slower form of accretion. So
removal is enforced the way every other AbyssBSD budget is enforced:
exceeding it is a **build failure**, not a regret logged for later
(`DESIGN.md` §3.6).

`cargo xtask ci` checks the public surface against `public-api.md` on every
change. The rule is absolute: **no public item may exist whose scheduled
removal epoch is at or below the current epoch.** If the current epoch is N
and any item is still present that was scheduled for removal in epoch N or
earlier, CI fails.

The consequence is that cutting epoch N+1 is *defined* as "the epoch-N
surface, minus everything epoch N marked for removal, plus what is new."
The epoch cannot be advanced without performing the removals, because the
build does not pass until they are done. Removal stops being a discretionary
chore that competes with feature work and becomes the mechanical
precondition of the epoch bump. A human can defeat this only by actively
un-scheduling a removal, which is a visible, reviewable edit to
`public-api.md`, not a silent omission.

## 8. Enforcement at spawn: the broker

The bundle manifest already declares the interfaces and capabilities a
component needs (`DESIGN.md` §11.9, §11.14). It gains one field: the
**epoch** the bundle was built against. This rides the existing manifest;
it is not a new file. The field is specified concretely with the rest of
the manifest schema at Gate D (`design/broker-and-transport.md`).

The system supports **two live epochs**: the current epoch N and its
predecessor N-1. An application built for either spawns normally. This gives
every app exactly one epoch transition of grace: it keeps running unrebuilt
across a single epoch bump, and must be rebuilt before the next.

An application whose manifest declares an epoch older than N-1 is **refused
at spawn**, by the broker, with a clear diagnostic naming the app's epoch,
the supported range, and the fix ("built for epoch 1; this system supports
epochs 3 and 4; rebuild against the current toolkit"). There is no silent
compatibility shim in the resident set. The system says no, out loud, the
same way it rejects an X server and keeps Wayland support an optional later
layer (`DESIGN.md` §7, the §579 compat-layer stance). The honesty is the
feature: a refused app is a clear instruction, where a silent shim is a
permanent tax.

## 9. Compatibility is opt-in and out of tree

AbyssBSD ships **no backward-compatibility layer in the base** and none in
any resident process. The base carries exactly two epochs (section 8) and
nothing older.

If running an application built for a removed epoch is ever wanted, that
support is a **separately installed, out-of-tree package**: an epoch-shim
that translates an old epoch's public surface to the current one. It is
never in the base image, never in the idle desktop's memory budget
(`DESIGN.md` §3.6), and never on by default. A user who installs it has
chosen to carry its weight, and that weight is visible. This is the same
discipline as `dependency-allowlist.md` applies to dependencies, and the
same stance `DESIGN.md` takes on Wayland compatibility: a thing you may opt
into, never a thing the whole system pays for silently.

## 10. Scripting and Lua

Lua scripts cannot be compile-checked, so a removed field would otherwise
surface as silent wrong behaviour rather than an error. Two mechanisms close
that gap.

- **Introspection is generated from the live typed interfaces.** The
  scripting suite's introspect verb (`interfaces/scripting.md`) reports the
  current epoch's surface, derived from the typed message schemas. A field
  removed at an epoch boundary is simply absent from introspection, and a
  script touching it gets a clean, typed `unknown-field`-class error
  (`interfaces/README.md`, errors are values), never a silent misread.

- **The script bundle declares its epoch** like any other bundle (section
  8), and is subject to the same broker check.

An epoch-aware script linter, run ahead of time against a target epoch, is
the natural third mechanism. It is **deferred**: introspection plus the
runtime error make a removed field safe and observable already, and the
linter is an ergonomic improvement to add when the scripting surface is
large enough to warrant it (`DESIGN.md` §3.5). It is recorded in section 11
so it is not forgotten.

## 11. Deferred, named so it is not forgotten

- **The epoch-aware script linter** (section 10). Added when the scripting
  surface warrants it; introspection and the runtime error cover correctness
  until then.
- **The migration-tool format.** Sections 6 requires a migration to ship
  with each removal; the concrete shape of those tools (the rewriter
  harness, the schema transcoder) is specified with the first removal that
  needs one, not before (`DESIGN.md` §3.5). No public surface is frozen
  before v1, so the first real exercise of this policy is post-v1.
- **The manifest `epoch` field's encoding** is specified with the rest of
  the manifest schema at Gate D (`design/broker-and-transport.md`).

## 12. When this starts

No public surface is frozen before the first public release. Until then the
toolkit API, the scripting surface, the manifest, and the app-facing
interfaces are all still fluid, and `public-api.md` records them as
designated-public but pre-epoch. **Epoch 1 is the surface of the first
public release.** From that point the policy is live: every subsequent
change to a registered item is either additive (section 5) or a scheduled,
migrated, enforced removal (sections 6 and 7).
