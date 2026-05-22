# Tech debt

Implementations that **work but are not how they should be** — shortcuts
knowingly taken, and the corrections owed.

This is *not* the roadmap — planned future work is `DESIGN.md` §12 and
`ROADMAP.md`. It is *not* the acceleration register — performance
candidates are `acceleration.md`. An item here is a correction owed on
something already built.

Each item: what it is, why it is debt, and the proper fix.

---

## abyss-font — the per-`Font` freetype library

`crates/abyss-font` gives every `Font` its own `FT_Library` (commit
`306abfd`). That made font use race-free — but by **duplication**: N fonts
hold N freetype libraries, and none of freetype's or harfbuzz's
per-library caches (glyph outlines, sizing, shaping plans) are shared.

**Why it is debt.** It trades memory and cache reuse for thread safety. It
was the right *immediate* fix (CI had caught a data race), but the right
*shape* is to share a library, not clone it.

**Proper fix.** Share one `FT_Library` across the fonts on a thread rather
than one per font. A `Font` is `!Send` — it lives on the thread that
opened it — so a **thread-local `FT_Library`** is the natural fit: fonts on
a looper thread share that thread's library and its caches, with no lock
and no cross-thread race. (A single process-wide library behind a `Mutex`
is the alternative — it shares caches across all threads but serializes
face creation and rendering.) Choose between them with a benchmark.

## abyss-toolkit — no pointer capture

`Button` (`crates/abyss-toolkit`) tracks `pressed` from `PointerDown` and
`PointerUp`. A press *inside* the button followed by a release *outside*
it never reaches the button — the release hit-tests to a different view —
so the button is left stuck in the `pressed` state.

**Why it is debt.** A real interaction (press, drag off, release) leaves
the UI in a wrong state.

**Proper fix.** Pointer capture: a `PointerDown` grabs the pointer for the
hit widget; every pointer event then routes to the capturing widget until
the release, regardless of position. A standard toolkit mechanism — the
`ViewTree` input driver gains a "captured view" slot.

## abyss-render — text ignores a scaling transform

`Canvas::text` blits glyph masks at the `size_px` they were rasterized at.
Under a *translating* transform that is exact; under a *scaling* transform
the text does not scale — it stays at `size_px`.

**Why it is debt.** The `Canvas` transform is not honored uniformly: paths
scale, text does not.

**Proper fix.** Rasterize glyphs at the transform-scaled size. The
`GlyphCache` key already includes the pixel size, so a scaled request just
caches a distinct entry — cheap. Deferred only because the toolkit picks a
pixel size directly and rarely scales text through the canvas transform.

## abyss-broker — the session mints zero-rights capabilities

`Session::wire` (`crates/abyss-broker/src/session.rs`) gives every ring
endpoint it grants a `CapBody` of all zeros — an empty `cap_rights` mask
and no object rights — through `minted_rights()`.

**Why it is debt.** A bundle grant should carry the rights the manifest
asked for: the `broker-and-transport.md` §3.3 mapping turns a manifest's
`rights` tokens into a `cap_rights_t` mask (kernel-enforced) and an
object-rights set (service-enforced). The wiring is correct in every other
respect, but the capabilities it mints are unattenuated.

**Proper fix.** Build the §3.3 rights mapping — a per-interface table from
rights tokens to object-rights bits, and the socket `cap_rights` a ring
endpoint needs — and have `Session::wire` mint each grant's `CapBody` from
the requesting `CapabilityRequest`. The kernel side also needs
`cap_rights_limit` applied to the fd before it is sent; that is a Capsicum
step not yet built.

---

## Watch items

Not debt today, but to revisit:

- **`std::simd`** is nightly-only (`acceleration.md`). When it stabilizes,
  it becomes the preferred way to write SIMD fast lanes; revisit then.
