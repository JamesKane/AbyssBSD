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

### Terminal emulator — Ghostty-class

`DESIGN.md` §12 M1 already requires a real VT terminal, load-bearing from M1.
This item is the *bar* for it: Ghostty-class — fast, GPU-accelerated, modern.

- Ghostty is MIT-licensed but written in Zig with its own renderer; a fork is
  impractical. Design target, not codebase.
- The M1 terminal should be **built to grow into this**, not replaced later.

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

## Communication

### Email client

A desktop mail client — local-first store, IMAP/SMTP.

- Capability-scoped network access (§10), declared in its manifest.
- Could index mail into the §11.16 model, making mailboxes and filters live
  queries like the media and photo libraries.

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
no Gecko, no inherited billion-line dependency — targeting standard,
well-specified HTML5 and CSS. Not the moving target of whatever a
surveillance-funded ad company shipped this quarter, but the open web as a
*documented standard*: the **pre-enshittification web** — standards-first,
user-first, small enough to understand.

- **The largest item in this file, by several-fold.** A modern web engine is
  plausibly more effort than everything else here combined — a multi-year
  programme, not an app. Recorded as a long-horizon ambition, not a near-term
  candidate, and not to be sized or scheduled alongside the others.
- Inspiration, not a fork: Ladybird is the design exemplar and the proof that
  an independent engine is possible. The codebase question stays open, but the
  engine must end up native to the Kit toolkit (§8) like everything else here.
- Was briefly described on the public ecosystem page; pulled back here until it
  is real enough to commit to.

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
