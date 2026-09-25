# Phase 11 — the theme system, layers 1–3 (scope)

Ship an opinion without compiling it in. Read [PLAN.md](PLAN.md) for the
dependency order (this phase is `Before` 15, and cheaper the sooner it lands),
[PRODUCT.md §8](PRODUCT.md) for the architecture — four layers, a theme is data
and not code, and what a theme may not break — and [HANDOFF.md](HANDOFF.md) for
the traps: §2.9 (one layout function feeds paint and hit-test), §2.37 (a probe
with no positive control) and §2.45 (a silent fallback is invisible) are this
phase's whole discipline.

Last updated: 2026-09-25. **Scoped. The plan was re-measured and four risks
were spiked before this was written** (§4). The main change is that the second
theme now has a real specification. The **Plan Neo chrome study**
([artifact](https://claude.ai/artifact/M4LEDkHLwxppcSSk6gsR7E)) is Trench (PLAN
§11.1) drawn in full, and it shows the plan as written would not have reached
it: the drawing vocabulary is too small, icons and fonts are missing, and the
migration is three times the size the plan counted.

---

## 1. What this phase is

> Today Jaguar is not a theme. It is the only thing the code can draw. Colours
> are `static let`s. Controls are 27 functions of straight-line cairo. Icons
> are Swift. The window frame is a hard-coded layout that the client and the
> compositor each read. Eight `…Metrics` enums fix the shell's geometry. And
> 710 cairo calls in the application code paint around all of it.

The claim this phase has to make:

> **Two themes that share nothing come out of one interpreter, with no code path
> of their own.** Jaguar is re-expressed in the format, pixel-identical to
> today's, and remains the default. Trench — Plan Neo's look — renders the same
> scenes: bevels, brushed metal, glow, LCD type and Amiga gadgets. It needs no
> Swift that knows its name. A theme that fails the legibility floor is refused,
> or warned about (§6.2), with a reason a person can read.

### What changed since PLAN.md wrote Phase 11

| PLAN.md said | Measured 2026-09-25 |
|---|---|
| 192 `Theme.` call sites in 14 files | **253 in 16 files** |
| — | **83 hard-coded `Color(hex:)`** outside `Theme`, in 7 files (Icons 31, Finder 8, Scene 6, Dock 6, Toast 4, …) |
| — | **710 raw `cairo_` calls in `de/aqua`**, bypassing `Draw` (Icons 159, Finder 143, Dock 100, Wallpaper 40, Scene 38, AquaMenu 34, MenuBarStatus 27, MenuBar 19, …) |
| — | **8 metrics enums** fixing geometry (`MenuBar`, `MenuBarStatus`, `Dock`, `Desktop`, `Finder`, `AquaMenu`, `Toast`, and undertow's `FrameMetrics`) |
| layer 2 = rounded rects, gradients, 9-slice, text, insets | Plan Neo also needs bevels, stripe patterns, noise, radial and **conic** gradients, masks, **glow**, inner shadow, text by role with case and tracking, ghost text (§2) |
| — | **icons are code** (`Icons.swift`), and the plan never mentions them |
| — | **fonts are a fixed file chain** with regular/bold/italic. Plan Neo needs four families by role |

The first row is the plan's own metric, and it grew by a third during Phases 9
and 10. The next three are why "no code path of its own" was unreachable as
written: Trench can only restyle what goes through the interpreter, and most of
the pixels do not.

---

## 2. What we already have vs. what's new

| Need | Have | New in Phase 11 |
|---|---|---|
| Tokens | `Theme`: 144 lines of `public static let`, compiled in | an instance loaded through `PoolConfig`, reached ambiently, with **schemes** (a theme has variants: neon, high contrast, daylight) and **derived colours** (`mix(raised, white, 14%)` in OKLCH, which Plan Neo does everywhere) |
| Theme parameters | none | **bounded numeric settings** a person can change — glow strength, bevel width, bloom — with ranges, used only by multiplication. That is how to stop the format growing a language (§6.5) |
| Widget drawing | `Draw`: 27 static functions of cairo | a **draw-list** format and one interpreter. `Draw`'s 27 become draw lists; the Aqua look is data |
| Primitives | rounded rects, linear gradients, pinstripe, text | + **bevel**, **stripe pattern**, **noise tile**, **radial** and **conic** gradients, **masks**, **glow**, **inner shadow**, square corners, and states: normal, hover, pressed, disabled, focused, **selected**, **active window** |
| Text | one fallback chain of font files (`ctext`), sizes, bold/italic | **roles** (chrome, interface, readout, mono) mapped to families by the theme; **case transform** and **tracking**; **ghost text** under a run (the LCD's unlit segments) |
| Fonts on disk | Noto / DejaVu / Adwaita, found by path | + **IBM Plex** (packaged on both platforms) and **Chakra Petch** and **VT323** (packaged on neither; vendored, OFL) — §4.3 |
| Window chrome | `Chrome.swift` hard-codes the traffic lights, and client chrome, undertow's server-side frames and both hit-tests each read it | **one chrome layout function from theme data**: which gadgets, which side, what size, and what the title does. It feeds all four (§2.9). Plan Neo puts close on the left and adds Amiga **depth** (send to back), which undertow cannot do yet |
| Shell geometry | 8 `…Metrics` enums | layer-3 data. The Dock's size and the bar's height and padding come from the theme; the Dock's **edge and orientation do not** (§6.1) |
| Icons | `Icons.swift`, procedural Swift, 31 colours, 159 cairo calls | **icons as data** in the same draw-list vocabulary (paths plus gradients), so one icon renders at every size. Aqua's and Trench's (BeOS-style) are both sets |
| App painting | 710 raw cairo calls in Finder, Dock, Wallpaper, menus, scenes | through `Draw` roles, or the theme cannot reach it |
| Legibility | nothing | a floor checked at load: contrast per foreground/surface **pair**, and minimum hit target |
| Foreign apps | `PortalSettings` reports `color-scheme` | a generated GTK/Qt palette from the same tokens |
| Regression gate | `AquaDemo` renders scenes to PNG, and nothing compares them | **golden images**, taken before the first change |

---

## 3. Ordered passes

The golden images come first, because everything after is "change it and prove
nothing moved". Tokens come before draw lists, draw lists before what uses them,
and both themes last, because they are the tests.

**P11.1 — the gate before anything moves. ✅ done.** Render every deterministic
`AquaDemo` scene (window, sysprefs, widgets, scroll, tabs, sheet, wallpaper,
menubar, dock, finder, installer screens, open menus and a server-side frame)
to PNG, commit them as golden images, and add a pixel diff to `run.sh` that
**fails on any change** and writes the diff image. Seen to fail once: change one
token by one step, and the diff names the scene. HANDOFF §5 has wanted this
since P5.4, and this phase cannot be verified without it.

**What P11.1 landed.**

- **`abyss/tests/golden.sh`** renders **26 scenes**:
  - every window scene, including sysprefs, widgets, scroll, tabs and sheet;
  - the Finder in icon and list view;
  - all eight installer pages;
  - the wallpaper, menu bar, Dock and notification toasts;
  - an **open menu**, and **the compositor's frame**;
  - four of them again at **2×**.

  It compares each with a committed golden **pixel for pixel** — identical,
  not "close", because a tolerance is a place for a change to hide.
- **Each scene renders twice first,** and a scene that differs from itself is
  refused as a golden.
- **The environment is pinned:** an empty config dir, `TZ=UTC`, and fake
  status items (`ABYSS_FAKE_VOLUME`/`_BATTERY`), so the machine does not leak
  in.
- **The comparator is `abyss/tests/pngdiff.c`** (C over cairo, no image
  library). It exits 0, 1 or 2, and writes a diff image with the golden dimmed
  and every changed pixel red. Failures leave actual and diff images in
  `.build/golden-diff/`.
- **`--update` rewrites the goldens**, on purpose. `run.sh` runs the gate in
  its fast section, in about a second.

Two scenes are new, **render-only** entry points (`AQUA_SCENE=menu`/`frame`),
because they were the two things the toolkit draws and nothing had pictured:
- **an open popup menu:** the Finder's real File menu, with enablement, key
  column, separators and one row hovered. It is rendered through a now-public
  `PixelBuffer` init;
- **`paintWindowChrome`:** the frame undertow paints around a foreign window.

**Goldens are per platform** (`abyss/tests/golden/linux`, `…/freebsd`, 1.2 MB
and 1.3 MB). The text is drawn in whatever fonts the box has, and the measured
difference is not subtle. The menu is **223 px wide on Linux and 226 on
FreeBSD** (DejaVu against Noto/Adwaita), and even the Dock differs in 426
pixels. One shared set would have been permanently red on one platform or the
other. The FreeBSD set was generated in the guest, with the guest's fonts.

**Seen to fail:** one channel of one token moved by one level (`menuHighlight`
`0x3f6fdf` → `0x3f6fe0`) moved pixels in **8 scenes**. They were the open menu
and every selection highlight in the Finder, the installer and the desktop,
each named with its pixel count and first coordinate. Restored, green.

**What it found, before anything moved:** **the compositor draws the Finder's
toolbar pill on foreign windows' frames.** `paintWindowChrome` always paints
it; undertow calls it for every server-side frame, and undertow's own
`frameHit` treats that spot as title bar. So what is drawn and what can be
clicked disagree (§2.9), on every GTK window since P9.6. It is visible in the
`frame` golden, recorded **as it is** because P11.1 is a baseline, and fixed in
P11.6, where one chrome layout function feeds paint and both hit-tests. That
fix updates the golden, on purpose.

**Verified:** green on Linux and in the FreeBSD guest (26 scenes each); the
fault above caught; `swift build` and the gate itself. (No long gates run,
since this is a sub-phase.)

**P11.2 — tokens become a theme. ✅ done.** `Theme` becomes an instance, loaded from
`themes/<name>/theme.ini` through `PoolConfig`. It holds tokens, schemes,
derived colours and parameters, and is reached through an **ambient current
theme**. It is not threaded through 253 call sites, and `undertow` reads the
same file for its frames. The 83 hard-coded colours become tokens. Aqua's
tokens are the first file, and the gate stays green, pixel for pixel.

**What P11.2 landed.**

- **`ThemeTokens`** is a struct holding every token, with Jaguar's exact values
  as its defaults. **`Theme.x` keeps its spelling at all 253 call sites.** Each
  one is now a computed read of `Theme.current`, the ambient loaded theme.
  That meant no call-site churn, and the first build after the change was
  already pixel-identical.
- **`ThemeLoader`** (`de/aquadraw/ThemeLoader.swift`) reads
  `themes/<name>/theme.ini` through `PoolConfig`'s parser, and is strict where
  that parser is lenient. It handles:
  - colours as `#rrggbb`, `#rrggbb/alpha`, `r g b [a]`, or `mix(a, b, t)` in
    **OKLCH**, lightness and chroma linear and hue the short way round, as CSS
    `color-mix(in oklch)`, which is what the Plan Neo study uses;
  - metrics as a number or `number * parameter`;
  - bounded `[parameters]`, clamped with a warning;
  - `[colors.<scheme>]` and `[metrics.<scheme>]` overriding the base.

  An unknown section or key, a malformed value, an undeclared parameter, an
  unknown scheme or a self-referential mix **refuses the whole theme**, naming
  the section, key and reason, and draws the compiled Jaguar instead.
- **Choosing a theme:** `appearance.ini` (`[appearance] theme`, `scheme`,
  `[parameters]`), Aqua by default.
- **The search path:** `$ABYSS_THEME_DIR`, then `<config>/themes`, then
  `<exe>/../share/abyss/themes`, then — in a build tree — the repo's `themes/`,
  found by walking up to `Package.swift`.
- **Every process says what it drew with.** Both `AquaDemo` and `undertow` load
  at startup and announce one line: `Theme: Aqua from …`, `NO THEME …` or
  `… REFUSED …`.
- **`themes/aqua/theme.ini`** is the first theme file: **116 tokens**, the
  original 75 plus 41 chrome colours that were literals in application code:
  - the Finder's toolbar, back button, list header and status bar;
  - the sysprefs toolbar and text, list stripes, sheet and toast colours;
  - the desktop gradient and its label colours;
  - the Dock shelf, separator, running mark and label;
  - the installer's veil, and the compositor's inactive-frame wash.
- **The medium carries `themes/`** in `/usr/local/share/abyss/themes`, and its
  cache fingerprint now covers the theme files.

**Where the boundary between tokens and recipes was drawn.** A token is a value
a theme sets. The gloss alphas *inside* `Draw`, such as a gel button's white
highlight stops, are the recipe for a widget, and become draw-list data in
P11.4, not tokens now. Icon artwork is P11.8: the Finder's file icons, the
Dock's glyphs and tile gradients, and `Icons.swift`. Moving those to tokens now
would only move them twice.

**What it found:**

- **The goldens would have passed on the compiled fallback.** The first run of
  the new check in `golden.sh`, "was this scene drawn from
  `themes/aqua/theme.ini`?", failed. The real binary is
  `.build/<triple>/debug/`, one level deeper than the `.build/debug` symlink,
  so the build-tree lookup missed the repo. The theme loaded from nowhere, and
  Jaguar drew identically from the fallback. **26 green goldens would have
  proved nothing about the file.** The lookup now walks up to `Package.swift`.
  The check stays, and the fault that proves it is an edited `theme.ini`,
  which moves the same 8 scenes an edited Swift token did.
- **SwiftPM does not recompile across a re-export** (HANDOFF §2.66).
  `ThemeTokens` grew by 41 fields. Targets that saw `AquaDraw` only through
  `Aqua`'s `@_exported import` were not recompiled, and ran with the old
  layout:
  - `AquaDemo` crashed on exit destroying a `ThemeLoader.Outcome` (signal 11);
  - the test bundle crashed;
  - earlier, a link failed on a symbol that had changed from stored to
    computed.

  They now depend on and import `AquaDraw` directly. That was proved by
  growing the struct by two fields and back again with no forced rebuild, and
  it ran both times. Every later pass in this phase changes that struct, so
  this would have recurred on each.
- **The medium's cache did not look at repository data.** Its fingerprint
  covered binaries, dist sets and packages. A theme edit would have booted an
  image built before it, green.

**Verified (short checks only):**
- the golden gate, pixel-identical on Linux **and in the FreeBSD guest**, with
  every scene confirmed drawn from the file;
- an edited `theme.ini` moves the expected 8 scenes;
- `swift test` on Linux, 474, green;
- `ThemeTests`: the shipped file equals the compiled Jaguar and sets every
  token; every colour form; OKLCH against known values (the black/white
  midpoint is sRGB 0.389, not 0.5); cross-token mixes and scheme overrides; a
  metric times a parameter; parameter bounds; every refusal by name; and a
  refused theme leaving `Theme.current` exactly Jaguar.

**Not run:** `live-medium.sh`'s new assertion that the booted medium drew from
`/usr/local/share/abyss/themes`, because it boots the medium (over a minute).
It is owed with the phase gates.

**P11.3 — the draw-list format and its interpreter.** A small line-oriented
declarative format (§6.4) with the §2 primitives, parameterised by tokens,
parameters and widget state. **Conic gradients are cairo mesh patches** (§4.1).
**Glow is a cached blur** of the element's mask, keyed by size, state and glow
strength (§4.2). Nothing in it executes, loops or branches beyond picking a
state. **Bench the interpreter** against the straight-line cairo it replaces,
because the toolkit is on the input-to-photon path.

**P11.4 — Aqua, in the format.** `Draw`'s 27 functions become draw lists
interpreted by P11.3. **The gate must stay pixel-identical.** This is the pass
that proves the format can say Jaguar. It is necessary and not sufficient
(PRODUCT §8.3), which is why P11.9 exists.

**P11.5 — the paint that goes around `Draw`.** The 710 raw cairo calls in
`de/aqua` move behind `Draw` roles, largest first: Finder, Dock, Wallpaper,
Scene, menus, status items. The eight metrics enums become layer-3 data. This
is the pass the plan did not count, and it is most of the diff. The gate stays
green throughout.

**P11.6 — chrome is theme data, and one function reads it.** The window frame's
gadgets, their side, order and size, the title's placement and weight, and the
frame's metrics come from the theme. **One chrome layout function** feeds the
Aqua client's own chrome, undertow's server-side frames, and **both hit-tests**
(`windowChromeHit`, `frameHit`), so what is drawn is what is clickable (§2.9).
The gadget set is **close, minimize, zoom and depth**. **P11.1 found the case
this pass exists for:** undertow's server-side frame paints the Finder's
toolbar pill, which its hit-test treats as title bar. That pill goes, and the
`frame` golden is updated on purpose. Depth, sending a window
to the back, is a new window operation in undertow, the one piece of
compositor work in the phase.

**P11.7 — type by role.** `ctext` loads families **by name** per role, from the
theme, with the existing fallback chain behind each. Runs gain **case
transform**, **tracking** and **ghost text**. Plan Neo's families ship:
- IBM Plex, from the package repos on both platforms;
- Chakra Petch and VT323, vendored under `fonts/` with their OFL licences
  (§4.3).

The medium carries all of them. `Text.announce` already says `NO GLYPHS` for a
missing menu glyph (P10.4). It learns to say which *role* fell back, and to
which face.

**P11.8 — icons are data.** `Icons.swift` becomes an icon set in the draw-list
vocabulary: paths, fills, strokes, gradients and a cast shadow. Aqua's set
reproduces today's icons under the gate. An importer for a small SVG subset is
a **build-time** tool that turns vector artwork into draw lists. There is no
SVG renderer in every process (§6.3).

**P11.9 — Trench: the Plan Neo look, and the test the format can fail.** A
second theme directory, and **no Swift that knows its name**:
- **Schemes:** `neon`, `neon-hc` and `daylight`, tokens taken from the study
  verbatim.
- **Materials:** anodized noise, brushed metal, bevels, and a backlit LCD with
  ghost segments.
- **Glow and fonts:** glow on focus and selection, with the study's `--gk` as
  a parameter. Chakra Petch UPPERCASE titles.
- **Chrome and icons:** Amiga gadgets, close on the left and zoom plus depth on
  the right, with a cyan underline and glow on the active window. BeOS-style
  icons in three-quarter perspective.

It renders the same `AquaDemo` scenes. **The check is structural as well as
visual:** `git grep -i trench -- 'de/*.swift'` finds nothing but the default
theme's name, and any other hit is a back door (PRODUCT §8.3). Trench also gets
golden images of its own, so it cannot rot silently.

**P11.10 — the floor, and the foreign applications.**
- **The legibility floor.** Contrast is checked per foreground/surface pair
  that the theme actually uses, with WCAG AA 4.5:1 for body text, plus a
  minimum hit target. It is checked at load, with the reason written in words
  (§6.2 decides refuse or warn). The study itself flags two of neon's tokens as
  failing on raised surfaces, so the floor's first real case is a design we
  were handed, not one made up to fail.
- **A generated GTK/Qt palette** from the same tokens, reported through
  `PortalSettings` beside `color-scheme`.

---

## 4. The spikes

### 4.1 Can cairo draw a conic gradient? — **Yes, as mesh patches, on both platforms.**

Plan Neo's knob has a knurled edge and a tick ring, and both are conic
gradients. Cairo has no conic pattern, but 1.18 has **mesh patterns**. Four
quarter-circle Coons patches around a centre reproduced a red → purple → blue →
purple → red sweep. Pixels read back at 0°, 45°, 90°, 180° and 270° were within
a few levels of the expected colours (e.g. 180° = `0,0,255`, 45° =
`192,0,64`). Cairo is 1.18.4 on Linux and 1.18.2 in the guest, the same API.
The primitive is a mesh builder, not a new dependency.

### 4.2 What does glow cost? — **Tens to hundreds of µs per element, if cached; a full-screen glow is layer 4.**

A glow is a blurred alpha mask, tinted. A 3-pass box blur, which approximates a
Gaussian, in plain C at `-O2`:

| Area | Radius | Per glow |
|---|---|---|
| 220×40 (a menu row) | 8 | **59 µs** |
| 930×60 (a title bar) | 16 | **374 µs** |
| 1440×960 (a screen) | 10 | 9.1 ms |
| 2880×1920 (4K-ish) | 20 | 36.8 ms |

Per element, cached by size, state and strength, it is cheap: a title bar's
glow is recomputed on resize, not per frame. **A whole-screen glow, blur behind
glass, or scanlines is layer 4**, the compositor's, with a declared cost
(PRODUCT §8.5). That waits on P4.5, because the frame contract does not yet
hold on real hardware.

### 4.3 Are Plan Neo's fonts available? — **IBM Plex yes, on both. Chakra Petch and VT323, on neither.**

- **IBM Plex:** Fedora has `ibm-plex-*-fonts` (Sans Condensed and Mono among
  them), and FreeBSD has `plex-ttf` 6.4.0.
- **Chakra Petch and VT323:** in neither package repository. Both are OFL
  (from Google Fonts), which permits redistribution with the licence, so they
  are **vendored** under `fonts/` with `OFL.txt` beside them.

The medium's font closure grows by four families. P5.3's lesson applies: copy
the files the roles name, not a package's closure.

### 4.4 Is there an SVG renderer to lean on? — **Yes, librsvg is on both. Recommend not using it at runtime.**

Fedora has librsvg 2.62, and FreeBSD has 2.62 (Rust) and 2.40 (C). An SVG
renderer in every application process is a large parser of theme-supplied files
living in the process that holds your windows. That is the surface PRODUCT §8.3
rejects dylibs for. Icons are drawn from the same draw-list vocabulary instead,
and an SVG *importer* is a build-time tool (§6.3).

---

## 5. Verification

Short checks by default. The phase gates, `run.sh --live`, `run.sh --vm
--live` and `--full`, run at the end of the phase, as agreed.

- **The golden-image gate** (P11.1), seen to fail on a one-step token change,
  and green through P11.2–P11.8 **pixel for pixel**.
- **Trench renders every golden scene** with no Swift of its own (the `git
  grep` check in P11.9), and gets golden images of its own.
- **Units, all pure:**
  - token loading, schemes, derived-colour maths and parameter bounds;
  - the draw-list parser, which rejects unknown ops with a line number;
  - the chrome layout, with each gadget's rectangle the same in paint and
    hit-test;
  - conic patch geometry, and blur-cache keys;
  - the legibility maths, against the WCAG formula and known pairs.
- **The interpreter bench**, against the straight-line cairo it replaced. The
  number is recorded, and a regression beyond an agreed margin fails.
- **Live:** undertow draws a foreign window's frame from the theme (both
  themes), and **depth** sends a window to the back — checked with the
  compositor's own stacking, not a log line.
- **The floor refuses (or warns about) a theme that fails it,** in words, and
  neon's two flagged tokens are the first case.

---

## 6. Risks and open decisions

**6.1 Plan Neo is more than a theme — and one part of it contradicts PRODUCT
§8.4.** About half of the study is shell structure, not appearance:
- NeXT-style docked vertical menus, a copy popped up at the pointer, and
  tear-off menus, **with no global menu bar**;
- the Dock on the right edge, vertical, with live tiles;
- a top bar showing the workspace and the output's mode;
- workspaces themselves;
- new widgets: knob, LCD readout, LED, cycle gadget, MUI page list, Miller
  columns.

None of that is layers 1–3, and Phase 11 does not build it. **But PRODUCT §8.4
says a theme may not remove the menu bar**, which would forbid Plan Neo
outright. **Recommendation:** restate the rule as the property it protects:
*every command stays reachable with the mouse, from one persistent,
discoverable place* (thesis 2). Record a **layer 5 — shell layout** for how
menus are presented, which edge the Dock takes and what the top bar shows.

Phase 10 already made this cheap. Menus are data (the vocabulary), so a NeXT
menu is a second **presenter** of the same `MenuBarModel`, not a second menu
system. Layer 5 is its own phase after Phase 13 (which brings workspaces),
not a pass here.

**6.2 The legibility floor: refuse or warn?** PLAN says refuse. The study's own
neon scheme fails AA in two pairs, so a strict floor would refuse the design as
handed over. **Recommendation:**
- **refuse** a theme whose *body text* fails its surfaces;
- **warn** — shown in Preferences, with the pair and the ratio — for secondary
  roles (dim text, disabled states), where 3:1 is the floor;
- ship neon with its two tokens nudged until they pass, and keep the study's
  values in the docs.

**6.3 Icons: in this phase, as data.** Leaving them as Swift keeps Trench from
being a theme, since BeOS-style icons are half of its identity. And a runtime
SVG renderer is the parser-in-every-process that §8.3 exists to avoid.
**Recommendation:** P11.8 as scoped, with draw-list icons and a build-time SVG
importer.

**6.4 The format's syntax.** `PoolConfig`'s INI holds tokens, schemes,
parameters and metrics well, and draw lists badly. **Recommendation:** a theme
is a directory:
- `theme.ini` for tokens, schemes, parameters, fonts and metrics, through
  `PoolConfig`;
- `draw/*.dl` for widget and chrome draw lists: one op per line, with named
  states;
- `icons/*.dl` for icons.

It is parsed by us, with unknown ops rejected with a line number, and no
Foundation, JSON or expressions beyond parameter multiplication.

**6.5 Scope creep: the format growing a language.** This is the risk the plan
already names (PRODUCT §8.6). The guards:
- parameters are bounded numbers, used only by multiplication;
- the only conditional is picking a widget state;
- derived colours are one `mix()`;
- anything else a theme wants is a port, trusted like a package.

**6.6 Fidelity and performance.** The golden gate makes fidelity a test. For
performance there is the interpreter bench, plus the glow cache (§4.2). The
toolkit is off C1's path but on input-to-photon.

**6.7 The compositor reads the theme.** undertow paints server-side frames
(P9.6) and must draw them from the same theme, reloaded when it changes. It
links `AquaDraw` already, so the interpreter lives there, and a theme's
failure to load in the compositor falls back to Jaguar, **loudly**, not to
blank frames.

**6.8 Submenus still do not open** (PHASE10 P10.8). No theme in this phase
needs them, but Plan Neo's cascading menus and the GTK/Qt menus from P10.6–7
do. **Recommendation:** fix it as a Phase 10 follow-up before P11.9, so Trench's
menus are judged opening, not just drawn.
