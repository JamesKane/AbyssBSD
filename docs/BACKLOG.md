# AbyssBSD — Backlog

> Uncommitted ideas — candidate applications for the native ecosystem
> (`DESIGN.md` §11.14, and the project's ecosystem stance: AbyssBSD does not
> run existing Linux UI apps, it grows its own).
>
> **This is not the roadmap.** The roadmap is `DESIGN.md` §12, M1–M5. An item
> here graduates to the roadmap only by a deliberate decision. Everything below
> is app-tier — it sits *beyond* M4's core apps (file manager, settings, text
> editor) — and nothing here is scheduled.

---

## Conventions

Each item, unless noted, is a native AbyssBSD application: a §11.14 bundle,
written against the one Kit toolkit (§8), capability-scoped (§10), inside the
§3.6 budgets. Where an existing app is named, **"fork vs. build native" is an
open question** — see [Cross-cutting questions](#cross-cutting-questions) — and
the named app is treated as a *design target*, not assumed to be a codebase.

---

## Developer tools

### Code editor — a Zed-class native editor

`DESIGN.md` §12 already scopes a text editor at M4; this is the *ambition* for
it: a Zed-class editor — fast, GPU-accelerated, responsive, language-aware.

- **Fork or build native?** Zed is Rust (aligns with §3.1), but ships its own
  GPU UI framework (GPUI) and a large dependency tree. Forking imports both,
  bypassing the single Kit toolkit (§8) and straining §3.2's zero-vendored-deps
  discipline. Zed is also GPL-3.0.
- **Likely AbyssBSD-coherent answer:** a native editor on the Interface Kit,
  with Zed as the design target rather than the source. To be decided.

### Graphical debugger — RemedyBG-class, for Rust and C/C++

A fast, native graphical debugger built to emulate **RemedyBG** — which stands
very nearly alone. Almost every other debugger is terrible: slow, opaque,
crash-prone, hostile to the work. RemedyBG is the explicit model, and the bar
the §3.5 review lens (Muratori, Blow) would recognise — speed and directness
over feature checklists.

- RemedyBG is Windows-only and proprietary — inspiration only, never a fork.
- Built native over **LLDB**, already in the toolchain (§5). Targets the two
  languages that matter here: **Rust** (the AbyssBSD layer) and **C/C++** (the
  FreeBSD base).
- "Measure; do not guess" (§3.5) turned into a tool.

### Hex file viewer & editor

A native viewer and editor for binary files — the hex/ASCII panes, offset
navigation, search, and structured inspection. A small, focused tool in the
§3.4 spirit, and a natural companion to the debugger above: inspecting file
formats, core dumps, and on-disk structures.

- Small enough to **build native** outright — no fork question, unlike the
  editor and terminal.
- Large-file handling is the one real design constraint: a memory-mapped file
  with a viewport-rendered view — only the visible rows laid out and drawn —
  fits the retained-mode toolkit (§8) and stays inside the §3.6 budgets
  whatever the file size.
- "Viewer" and "editor" are not two apps or a mode toggle: capability scoping
  (§10) decides which — a file handed in read-only simply cannot be written.

### Terminal emulator — Ghostty-class

`DESIGN.md` §12 M1 already requires a real VT terminal, load-bearing from M1.
This item is the *bar* for it: Ghostty-class — fast, GPU-accelerated, modern.

- Ghostty is MIT-licensed but written in Zig with its own renderer; a fork is
  impractical. Design target, not codebase.
- The M1 terminal should be **built to grow into this**, not replaced later.

### System inspector — the desktop made visible

A graphical view of the running system: the live component graph, the bus
connections between components, the capability graph, and each component's
memory against its §3.6 budget. The tinkerer's window into what the machine is
actually doing.

- Not nostalgia but identity: AbyssBSD's pitch is a system you can hold in your
  head, with "no hidden control flow, no magic" (§3.5). The broker already
  "can report the live picture, plainly and legibly, never an opaque blob"
  (§11.9); this app renders it.
- A pure consumer — it reads the broker's inspection surface and the scripting
  interface (§6.6), holds no authority over what it shows, and exports only
  scripting like any app.
- A genuine differentiator: almost no other desktop can show you its own
  structure honestly, because almost no other has one this legible.

---

## Library & media apps

These lean hard on the §11.16 typed-attribute + live-query data model — files
with typed attributes, "smart" collections as saved live queries. They would be
that model's first real showcase, and the argument for prioritising it.

### Media library & player — iTunes, before Apple ruined it

A local-first music/media library and player with the clarity of early-2000s
iTunes: a fast library, no streaming-store bloat, no account, no lock-in.

- Toolkit side: the **Media Kit** (§8, currently "later").
- Spine: the §11.16 data model — tracks are files with typed attributes,
  playlists and "smart playlists" are saved live queries.

### Photo library

A photo manager in the early-iPhoto spirit — local-first, fast, restrained.

- Same foundation: photos as files with typed attributes (EXIF, tags, dates);
  albums as saved live queries (§11.16).
- Pairs with the media library — the two could share a common "library app"
  pattern rather than each inventing one.

---

## Creative tools

The game-and-demo making corner — tools for the assets, and the framework to
build the thing itself.

### Raster painting & pixel art — a Deluxe Paint for the modern era

A fast, direct raster painting and pixel-art program in the spirit of Amiga
Deluxe Paint — the brush model (any grabbed region becomes a brush), palette
and indexed-color work, dithering and gradients, frame-based animation —
brought to modern displays, truecolor, large canvases, and pressure-sensitive
input.

- The spirit is the point: Deluxe Paint was instant and direct, never bloated.
  Aseprite and Grafx2 are the closest living relatives; a modern image editor's
  feature-sprawl is the cautionary tale. Held to the §3.5 lens like everything
  else.
- Native, built outright — no fork. The UI is the Interface Kit; the canvas is
  the app's own pixel buffer — immediate-mode painting beneath a retained-mode
  shell.
- A natural consumer of the input service's **tablet / stylus** events (§7.5)
  and of the image **codec ports** (§11.2) for load and save.
- Indexed-palette mode is first-class, not an afterthought — pixel art and the
  demoscene lineage need it; "modern era" *adds* truecolor, it does not
  replace the palette.

### Sound-effect generator — the sfxr / Bfxr lineage

A small, parameter-driven synthesizer for creating sound assets — the tool a
game maker reaches for to produce a pickup, a laser, an explosion, or a jump in
seconds: waveform and envelope controls, category presets, a randomize button,
and export to audio files.

- The lineage is sfxr → Bfxr → jfxr / ChipTone / rFXGen; the exact exemplar
  matters less than the shape — instant, fun, focused, deliberately tiny.
- Native, built outright — no fork. The synthesis is the app's own DSP
  (oscillators, envelopes, filters), small code rather than a Media Kit job.
- Previews play through a playback-scoped audio capability (§11.13); export is
  to WAV directly, or to compressed formats through the codec ports (§11.2).
- Pairs with the paint program above — both are game-asset creation tools, and
  AbyssBSD already takes games seriously (direct scanout, §7.4).

### Music tracker — the FastTracker / Renoise lineage

A pattern-based music tracker for composing game and demo soundtracks — the
demoscene's own instrument, from ProTracker and FastTracker II through to
Renoise and OpenMPT. Samples and synthesized instruments arranged in patterns:
fast, keyboard-driven, made for getting a tune down quickly.

- Native, built outright. Mixing and playback are the app's own DSP; preview
  and output go through a playback-scoped audio capability (§11.13).
- Completes the Creative-tools trio with the paint program and the sfx
  generator — art, sound effects, and now music: every asset a small game or
  demo needs.
- Sample import/export through the codec ports (§11.2); module formats are the
  app's own concern.

### Game framework — a RayLib for AbyssBSD

A small, friendly, batteries-included library for making simple games and
graphical toys — open a window, draw shapes and sprites, play a sound, read
input — with no engine, no editor, and no scene graph. RayLib is the spirit:
the easy on-ramp, not Unity.

- A **library**, not an app — the one such entry here, and plausibly
  semi-first-party: the friendly front door to AbyssBSD's own client APIs for
  game-shaped programs.
- It rests on what the OS already gives games: a display surface and input
  (§7.4), direct scanout for going fullscreen (§7.4), a playback audio
  capability (§11.13), and the codec ports for textures and sound (§11.2).
- The counterpart to the asset apps above — the framework you build the game
  with; the paint program, sfx generator, and tracker make what goes in it.
- Restraint, as everywhere (§3.5): the simple-games on-ramp. A heavyweight
  engine is explicitly not the goal.

---

## Communication

### Email client

A desktop mail client — local-first store, IMAP/SMTP.

- Capability-scoped network access (§10), declared in its manifest.
- Could index mail into the §11.16 model, making mailboxes and filters live
  queries like the media and photo libraries.

### IRC client

A native IRC client — the precise anti-Discord: local, scriptable, owned, no
telemetry, no server you do not control. Small, and a natural fit for an
audience escaping centralized chat.

- Capability-scoped network access (§10), declared in its manifest, like the
  email client.
- A strong candidate for the Lua scripting host (§6.6): IRC's culture has
  always been scripts and bots — and here a script is a capability-scoped
  bundle, not ambient automation.

### RSS / feed reader

A native feed reader — RSS and Atom — for following sites directly: the IRC
client's instinct applied to *reading*. The feed is a list you own and curate,
not an algorithm's product — no ranking, no engagement metrics, no account.

- Capability-scoped network access (§10), declared in its manifest, like the
  email and IRC clients.
- A natural fit for the §11.16 typed-attribute model — articles as items with
  typed attributes, unread and saved-search folders as live queries, the same
  pattern as the media and photo libraries.
- Pairs with the web browser: the reader follows the feeds, the browser opens
  the full article.

---

## Productivity suite

A native, opinionated trio in the **iWork sensibility** — well-designed and
restrained, explicitly *not* the feature-sprawl of Office or LibreOffice
(§3.3, opinionated).

- **Word processor** — Pages-like.
- **Spreadsheet** — Numbers-like.
- **Presentation** — Keynote-like.

**Open question:** a *shared document model* and layout/rendering core across
the three would avoid §3.4 duplication and keep the suite coherent — worth
designing once, up front, rather than three times.

---

## Web browser

A clean-room, independent web engine in the spirit of **Ladybird** — no Blink,
no Gecko, no inherited billion-line dependency. Its distinguishing bet is
**native hypermedia** and first-class **zero-JavaScript apps**.

The engine targets standard, well-specified HTML5 and CSS — the open web as a
*documented standard*, the **pre-enshittification web** — and builds a
hypermedia extension into the engine itself: the htmx / Hotwire idea (any
element may issue a request and swap an HTML fragment in place), native rather
than shimmed in JavaScript. A page can then run under `script-src 'none'` — no
framework, no SPA, no XSS surface — with event interception, fetch, and DOM
morphing done in the engine. Full design exploration:
`docs/design/hypermedia-browser.md`.

- **Native hypermedia is the strategic point.** It lets the browser opt out of
  the JavaScript arms race — *excellent* at HTML/CSS and hypermedia, merely
  *adequate* at heavy JS, because the good apps stop needing heavy JS. That is
  how a from-scratch engine stays comprehensible instead of becoming the
  multi-year monster this entry otherwise warns of.
- **Standards-compliant, plus an honest extension.** The hypermedia attributes
  are an AbyssBSD extension until standardized, and are designed to *degrade* —
  unknown attributes are inert, so every hypermedia control is also a working
  plain `<form>` or `<a>`. Progressive enhancement, not a fork of the web.
- **Still the largest item in this file, by several-fold** — a modern engine is
  plausibly more effort than everything else here combined, a multi-year
  programme. The hypermedia extension is cheap *relative to* the engine, but it
  does not shrink that baseline.
- Inspiration, not a fork: Ladybird is the design exemplar and the proof an
  independent engine is possible; the codebase question stays open. The engine
  must end up native to the Kit toolkit (§8) like everything else here.
- The hypermedia model is also the most promising answer to the parked
  "accessible creation / HyperCard" question — a zero-JS hypermedia app, served
  even from a local source, is HyperCard-shaped.

---

## Cross-cutting questions

- **Fork vs. native rebuild.** Recurring for the editor and terminal. Forking a
  Rust/Zig app imports its UI framework and dependency tree, bypassing the
  single Kit toolkit (§8) and straining §3.2. Default lean: existing apps as
  *design targets*, codebases native. Decide per app.
- **The §11.16 data model is shared infrastructure** for the media, photo, and
  email libraries — these items are also the case for prioritising it.
- **A shared document/layout core** for the productivity suite.
- **Sequencing.** All of this is app-tier, beyond M4 — and the web browser is a
  long-horizon programme well beyond even that. Nothing here is committed; this
  file is a holding area, not a plan.
