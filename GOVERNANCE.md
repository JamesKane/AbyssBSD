# AbyssBSD Governance — RFC and adoption process (DRAFT v1)

> "Formal informal": structure, not bureaucracy.

This document describes how AbyssBSD changes: who decides, how proposals
are written and reviewed, what gets shipped, and what stays the same. It is
itself amended via the process it describes.

There is no standards body. There will not be one until AbyssBSD catches
fire, meaning real adoption beyond the BDFL's own work: independent
downstream systems, outside contributors, and an application ecosystem with
external authors. Until then the project is meritocracy-driven and largely
guided by a [BDFL](#11-the-bdfl-role). The triggers that change this, and
what the model becomes when they fire, are documented in
[§8](#8-the-catches-fire-trigger).

## Contents

- [1. Governance](#1-governance)
- [2. What counts as an RFC](#2-what-counts-as-an-rfc)
- [3. The FreeBSD base boundary](#3-the-freebsd-base-boundary)
- [4. RFC format](#4-rfc-format)
- [5. RFC lifecycle](#5-rfc-lifecycle)
- [6. Reversibility](#6-reversibility)
- [7. Design invariants — what RFCs cannot casually overturn](#7-design-invariants--what-rfcs-cannot-casually-overturn)
- [8. The "catches fire" trigger](#8-the-catches-fire-trigger)
- [9. Practical defaults](#9-practical-defaults)
- [10. Code of conduct and contribution](#10-code-of-conduct-and-contribution)
- [11. Amendments to this document](#11-amendments-to-this-document)
- [Appendix A — design captured before this process](#appendix-a--design-captured-before-this-process)
- [Appendix B — acknowledgements](#appendix-b--acknowledgements)
- [Appendix C — RFC template](#appendix-c--rfc-template)

## 1. Governance

### 1.1 The BDFL role

The current BDFL is **James Kane**, project initiator and architect of
AbyssBSD. The BDFL has final authority on all decisions about the AbyssBSD
layer: the unified message primitive and the wire format, the
object-capability model, the component interface schemas, the public
surface and its epochs, the toolkit API, the performance and memory
budgets, the dependency allowlist, and the FreeBSD-base boundary. The BDFL
sets design direction, arbitrates between proposals, and renders the final
decision on every RFC that reaches the [decision stage](#54-decision).

During the pre-v1 phase the project repository is the BDFL's; channels for
outside contribution are announced as the project opens to them.

The role exists because at pre-v1, with no production deployments beyond
the BDFL's own use, and with the system still rapidly evolving across many
simultaneously-moving pieces (bus, broker, compositor, toolkit, shell),
decisions need to be made fast and coherently. Committee-driven processes
at this scale produce churn and weakly-defended compromises. A BDFL trades
that off for the cost of being one person's worldview: defensible at this
stage, untenable past the [catches-fire
trigger](#8-the-catches-fire-trigger).

The BDFL is not infallible. See [§6 reversibility](#6-reversibility).

### 1.2 Core team

Initially: the BDFL alone. The core team may grow informally as
contributors prove out. A contributor becomes a core team member by
sustained, high-quality work across multiple RFCs, by the BDFL's
invitation, and with no formal ceremony.

Core team membership grants:

- Read-and-comment standing on every RFC under discussion.
- The ability to **shepherd** RFCs through the lifecycle, see
  [§5.2 Draft](#52-draft).
- A non-binding vote on contested design calls; the BDFL still decides.

It does not grant write access to `main` without review. The project does
not have separate "committers": every change goes through review,
including changes by the BDFL.

### 1.3 Succession

The BDFL may name a successor in writing at any time. The named successor
takes over immediately on transfer.

If the BDFL becomes inactive, defined as no public activity on the project
for **12 consecutive months** without a named successor, the core team may
elect a new BDFL by simple majority vote among current core team members.
If there is no core team, the project is considered dormant; recovery
requires the BDFL or named heirs to reactivate, or a clean fork.

## 2. What counts as an RFC

### 2.1 RFCs are required for

- Changes to the unified message primitive or the wire format: the
  envelope, the typed-value vocabulary, the `#[derive(Wire)]` contract
  (`docs/design/wire-format.md`, `DESIGN.md` §6).
- Changes to the object-capability model: capability representation,
  enforcement, delegation, the broker protocol (`DESIGN.md` §10, §11.9).
- Any change to the public surface as defined by `docs/public-api.md`,
  including a removal and any **epoch bump** (`docs/design/api-evolution.md`).
- Changes to a component interface schema (`docs/interfaces/*.md`).
- Changes to the toolkit API (`abyss-toolkit`, the Interface and
  Application Kits).
- Changes to the performance and memory budgets, both the budgeted values
  and what is enforced (`DESIGN.md` §3.6).
- Adding or removing a dependency: a Rust crate to or from the allowlist
  (`docs/dependency-allowlist.md`), or a FreeBSD port the AbyssBSD layer
  depends on (`DESIGN.md` §11.2).
- Changes to the FreeBSD-base boundary, meaning what the AbyssBSD layer
  provides versus what the base provides (`DESIGN.md` §2, and
  [§3](#3-the-freebsd-base-boundary) below).
- The API evolution policy and the epoch mechanism itself.
- This document and any other governance doc.

### 2.2 RFCs are NOT required for

- Bug fixes (the prior behaviour was unintended).
- Diagnostic improvements: error messages, hints, location precision.
- Internal refactors that do not change observable behaviour.
- Performance optimisations with no observable behavioural effect and that
  stay within budget.
- Documentation, and routine maintenance of the registers
  (`acceleration.md`, `TECH-DEBT.md`, `public-api.md`).
- **Additive** changes within the current epoch that follow an established
  pattern obviously enough that the BDFL can wave them through in code
  review: a new optional message field, a new widget following the
  toolkit's conventions, a new method on an existing interface. Additive
  change is already free within an epoch (`api-evolution.md` §5); the BDFL's
  discretion here is wide. A whole new public interface is an RFC. When in
  doubt, file a [pre-RFC](#51-pre-rfc).

### 2.3 When in doubt, pre-RFC

A pre-RFC is a short (one paragraph to one page) sketch posted as an issue
with the `pre-rfc` label. Within ~14 days, the BDFL or a core team member
will say one of:

- **"Write the RFC."** The change is worth pursuing through the full
  process.
- **"PR directly."** The change is below the RFC threshold.
- **"Won't be accepted."** Saved the author from writing an RFC for an idea
  that won't fly. The rationale is recorded in the issue.

Pre-RFCs are not commitments to accept; they are commitments to respond.

## 3. The FreeBSD base boundary

AbyssBSD is an opinionated desktop layer on a **FreeBSD base kept whole and
tracked upstream, never forked** (`DESIGN.md` §2, §5). That boundary is a
governance fact, not only a design one.

This process governs the **AbyssBSD layer** alone: the bus, the broker, the
compositor, the toolkit, the shell, the services, the apps. It does not
govern the FreeBSD base.

- A change wanted in the base, meaning the kernel, libc, drivers, or the
  toolchain, is filed **upstream with FreeBSD**, through FreeBSD's own
  process. It is not an AbyssBSD RFC.
- An RFC that proposes forking the base, or that smuggles a base
  modification into the AbyssBSD layer to avoid upstreaming it, is sent back
  for redesign. "Do not fork the base" is a [design
  invariant](#7-design-invariants--what-rfcs-cannot-casually-overturn).
- Where the AbyssBSD layer must adapt to the base, for example a `drm-kmod`
  capability gap, the RFC documents the base version it assumes and treats
  the base as a fixed dependency, the same way it treats an allowlisted
  port.

This co-design is a feature at this stage: the same person is responsible
for the layer and for tracking the base, so drift between what the layer
assumes and what the base provides is caught fast. The discipline is to
keep the two clearly separated in every proposal.

## 4. RFC format

An RFC lives at `rfcs/RFC-NNNN-short-kebab-name.md` once it reaches Draft
status.

### Frontmatter

```yaml
---
rfc-id: RFC-NNNN
title: <short, declarative title>
status: pre-rfc | draft | discussion | accepted | rejected | withdrawn | deferred | implemented | stabilised
author: <name>, <name>
shepherd: <BDFL or core team member>
created: YYYY-MM-DD
last-updated: YYYY-MM-DD
applies-to: bus | capabilities | interfaces | toolkit | compositor | broker | packaging | budgets | base-boundary | governance
supersedes: RFC-NNNN  # optional
superseded-by: RFC-NNNN  # optional
implementation: <PR / branch / "TBD">
---
```

### Required sections

1. **Summary** — one paragraph. The whole proposal in 100 words.
2. **Motivation** — why this is worth doing. What bug class, friction,
   capability, or use case is being addressed.
3. **Design** — the proposal itself. Detailed enough that a competent
   engineer can implement it. Worked message schemas, interface fragments,
   capability flows, or API signatures where relevant.
4. **Examples** — at least one user-facing or component-facing example
   showing the feature in idiomatic use, plus one negative example showing
   what is rejected, and how (an `Error` value, a refused capability, a
   decode failure).
5. **Alternatives considered** — at least two, each with rejection
   rationale. "We considered nothing else" is never acceptable for a
   non-trivial RFC.
6. **Costs and tradeoffs** — surface area added; learning curve;
   implementation complexity; budget impact (`DESIGN.md` §3.6); interaction
   with other components.
7. **Backwards compatibility / migration** — what existing code or app
   bundles break; the migration path; and explicitly whether the change is
   additive (no epoch bump) or subtractive (an epoch bump with the
   deprecate-schedule-migrate obligation of `api-evolution.md` §6).
8. **Open questions** — things the author isn't sure about and wants
   reviewer input on.

### Optional sections

- **Prior art** — pointers to other systems, papers, precedents. BeOS,
  Haiku, and FreeBSD precedent is especially welcome.
- **Reference implementation** — pointer to a branch or PR, even if
  incomplete.
- **Test fixtures** — pointer to positive and negative tests, golden
  vectors where a wire format is touched.
- **Spec text** — pre-written prose for inclusion in `DESIGN.md`, a
  `docs/design/` elaboration, or an `interfaces/*.md` schema if accepted.

### What does NOT belong

- Marketing copy. The RFC is a design document, not a pitch.
- Apology or hedging. Anyone can propose; just propose.
- Implementation pseudo-code, except where the algorithm itself is the
  load-bearing detail.
- Comparison tables versus other desktops, beyond what is needed to
  motivate the design. The `site/` pages are where the comparison narrative
  lives.

## 5. RFC lifecycle

```
   pre-RFC  ->  draft  ->  discussion  ->  decision
                                             |
                               +-------------+-------------+
                               |             |             |
                             accepted     rejected    deferred / withdrawn
                               |
                          implementation
                               |
                           stabilised
```

### 5.1 Pre-RFC

An issue with the `pre-rfc` label. See [§2.3](#23-when-in-doubt-pre-rfc).
Response target: 14 days.

### 5.2 Draft

The author opens a PR adding `rfcs/RFC-NNNN-name.md`. Status: `draft`. The
author iterates on early feedback, meaning typo fixes, clarifications, and
scope corrections, before formally requesting review.

A **shepherd** is assigned at this point: a core team member or the BDFL who
consolidates reviewer feedback, flags missing sections, and decides when the
RFC is ready to move to Discussion. The shepherd is not the BDFL deciding
the merits; they are the editor responsible for the RFC's readiness.

### 5.3 Discussion

Status moves to `discussion` when the shepherd is satisfied the draft is
reviewable. Open to public comment for at least **14 days**. The author may
revise during discussion; large revisions reset the 14-day clock.

### 5.4 Decision

After discussion, the shepherd summarises the feedback and the BDFL renders
the decision:

- **Accepted** — ship as designed, or with revisions documented in the
  RFC's body. The RFC may move directly to implementation, or be held until
  a named milestone or phase (`ROADMAP.md`).
- **Rejected** — not pursued. Rationale recorded in the RFC and in the
  closing comment.
- **Withdrawn** — author chose to abandon. Reason recorded.
- **Deferred** — promising but not now. Reactivates at a named milestone
  (for example post-M1, post-v1, or a named epoch).

Target: 30 days from `discussion` opening to decision. If the BDFL is
leaning toward rejection, this is signalled in the discussion thread before
the formal decision. No surprise rejections.

### 5.5 Implementation

An Accepted RFC is not "done." Implementation follows the project's
**phase-exit-gate** pattern (`ROADMAP.md` §4 phases and §5 design-
elaboration gates):

- Code lands on `main` behind any required gating (a seam, a feature flag,
  or a `pre-epoch` status on a public-surface change) if needed.
- An end-to-end test exists that exercises the feature on the happy path.
- At least one negative test exists (an input or request that should be
  rejected and is).
- The relevant design text is updated: a `DESIGN.md` section, a
  `docs/design/` elaboration, or an `interfaces/*.md` schema.
- The registers are updated where the change touches them: `public-api.md`
  for public surface, `TECH-DEBT.md` for a shortcut knowingly taken,
  `acceleration.md` for a new hot path.
- `STATUS.md` is updated per the `ROADMAP.md` §7 convention.
- The `site/` pages are updated if the change is user-visible.
- The change stays within the performance and memory budgets, which
  `cargo xtask ci` enforces as a wall (`DESIGN.md` §3.6).

Status moves to `implemented` when the above land on `main`.

### 5.6 Stabilisation

For RFCs that affect the public surface (`public-api.md`), the implemented
feature is `pre-epoch`, meaning fluid, until it is folded into an epoch
(`api-evolution.md` §12). During that period:

- The shape may still change without a new RFC.
- Real consumers, meaning the toolkit, the shell, the example apps, and the
  scripting surface, try the feature.
- The BDFL declares it part of the next epoch when there is sufficient
  evidence the design holds up under use.

A feature folded into an epoch can be changed only via a new RFC, see
[§6](#6-reversibility).

## 6. Reversibility

- An **Accepted** RFC that has not yet been Implemented can be revised or
  withdrawn at any time.
- An **Implemented** RFC that has not yet been folded into an epoch can be
  revised; the revision goes through Discussion and Decision again, but
  typically faster (the design is mostly settled).
- A feature **folded into an epoch** can be changed only via a new RFC that
  references the original and explicitly satisfies `api-evolution.md` §6:
  deprecate the item, schedule its removal epoch, and ship the migration in
  the same change.

There is no shame in withdrawing or revising. The cost of shipping a wrong
design is higher than the cost of revising in flight.

## 7. Design invariants — what RFCs cannot casually overturn

Some properties of AbyssBSD are load-bearing for the project's identity. An
RFC that proposes to change one starts at a strong presumption against, and
the author has to make the case that the **invariant itself** should be
revised: a separate, larger discussion than the RFC body. These are drawn
from `DESIGN.md` §3 and the README.

- **The FreeBSD base is never forked.** It is kept whole and tracked
  upstream (`DESIGN.md` §2, §5). See [§3](#3-the-freebsd-base-boundary).
- **One message primitive.** A single typed message carries UI events,
  inter-thread traffic, IPC, the display protocol, and capabilities. RFCs
  that propose a second IPC mechanism, a D-Bus analogue, start at "no"
  (`DESIGN.md` §6).
- **Capabilities, not ambient authority.** A process is born holding
  nothing; authority travels only as unforgeable handles in messages,
  kernel-enforced by Capsicum and jails. RFCs that introduce ambient
  authority start at "no" (`DESIGN.md` §10).
- **No X11, no Wayland in the base.** The compositor is from-scratch.
  Wayland compatibility, if ever built, is an optional out-of-tree layer,
  never resident (`DESIGN.md` §7).
- **Zero vendored dependencies.** The AbyssBSD layer leans on the Rust
  standard library and a small, version-controlled allowlist. RFCs that add
  a dependency outside the allowlist process start at "no" (`DESIGN.md`
  §3.2, `docs/dependency-allowlist.md`).
- **Budgets are walls.** The idle-desktop memory budget (~256 MB at 4K) and
  the input-to-photon latency budget (at most one refresh interval) are
  enforced as build failures, not aspirations. An RFC that relaxes a budget
  rather than meeting it starts at "no" (`DESIGN.md` §3.6).
- **Written in Rust, pinned to stable.** No nightly-only features in
  shipped code. An RFC that depends on a nightly feature is deferred until
  that feature stabilises (`DESIGN.md` §3.1).
- **One thing well, replaceable at the seam.** Every component does one job
  behind an enforced message interface, and is swappable there (`DESIGN.md`
  §3.4).
- **Errors are values.** Interface failures are ordinary `Result`-style
  values, never exceptions or stack unwinding; `panic!` is for defects only
  (`docs/interfaces/README.md`).
- **The broker is the sole minter of authority**, and it does not subsume
  FreeBSD's `rc` or grow into init (`DESIGN.md` §10, §11.9).
- **Measure, do not assume.** Performance work builds the scalar thing
  first and accelerates only what measurement proves hot; the review lens
  applies to every increment (`DESIGN.md` §3.5, `docs/acceleration.md`).
- **Hold it in your head.** Surface area is a cost. An RFC that grows the
  system without a commensurate simplification faces the §3.5 review lens
  directly.

An RFC that wants to revise an invariant in this list must be **explicit
about it in the Motivation section**. The shepherd will reject silent
invariant changes.

## 8. The "catches fire" trigger

This document describes the process for the **pre-v1, BDFL-driven** phase
of AbyssBSD. The BDFL model and centralised authority are appropriate
while:

- There are no independent downstream systems built on the AbyssBSD layer.
- Outside contribution is zero or few.
- The system is rapidly evolving and decisions need to be coherent across
  many simultaneously-moving pieces.

AbyssBSD is a complete operating system, not a component consumed by other
projects, so it has no "adopted outside its canonical target" axis the way
a language does. Its analogue of catching fire is **a real community
forming around it**: people running it, people building on it, and people
shipping applications for it. The trigger below is defined so the model
does not flip over a flash in the pan, and is not held hostage to
subjective claims about momentum.

### 8.1 Trigger conditions

1. **Independent downstream systems** — three or more independent
   distributions, redistributions, or substantial forks built on the
   AbyssBSD layer. *Independent* means distinct teams or organisations, not
   one party with three spins. Each must be in real use, meaning installed
   and run by people other than its own author.
2. **Sustained external contribution** — three or more contributors from
   outside the BDFL's organisation, each landing at least one accepted RFC,
   over a rolling 12-month window.
3. **External application-ecosystem traction** — published AbyssBSD
   application bundles by external authors, depended on by an independent
   user base or by other projects, counted only when at least three
   distinct organisations are involved. This is the ecosystem the public
   surface and the epoch policy exist to serve (`api-evolution.md`,
   `site/ecosystem.html`).

### 8.2 Revision

When **two of the three conditions** above are met for a **sustained
6-month period**, this document is revised by:

- Forming a steering committee: 3 to 5 members, drawn from the current core
  team plus elected representatives of external contributors meeting
  condition (2).
- The BDFL retains the title **Lead Architect** and a **veto on changes to
  the design invariants in [§7](#7-design-invariants--what-rfcs-cannot-casually-overturn)**,
  but loses unilateral authority over all other decisions.
- The RFC process adopts a more formal model, with documented voting and
  acceptance criteria, likely modelled on the Rust RFC or Swift Evolution
  process.
- The committee reviews whether the governance change alters any stability
  commitment in `public-api.md`, and if so schedules the change at an epoch
  boundary like any other.

The revision is itself an RFC (a meta-RFC) and goes through the process
described in this document, with the steering committee formation as the
first amendment.

### 8.3 Early signal

The BDFL is encouraged to start mentoring potential steering committee
members **before** the trigger fires, not after. Smooth governance
transitions are easier than discontinuous ones.

## 9. Practical defaults

- **Don't draft RFCs for changes obviously below the threshold.** Send a
  PR. The reviewer will tell you if it needed an RFC.
- **Don't draft full RFCs for changes obviously above the threshold without
  a pre-RFC first.** A one-page sketch saves a week of writing for an idea
  that won't fly.
- **Default SLAs:**
  - Pre-RFC response: 14 days.
  - Decision after Discussion opens: 30 days.
  - These are targets, not hard commitments.
- **No surprise rejections.** If a Discussion-stage RFC isn't going to be
  accepted, the BDFL says so in the thread before the formal decision.
- **No silent stalls.** An RFC that hasn't moved in 60 days gets a status
  check from the shepherd. If the author is unresponsive, the RFC moves to
  `withdrawn`.

## 10. Code of conduct and contribution

- See `LICENSE` for licensing terms (BSD 2-Clause).
- Be civil. Disagreement is welcome; personal attacks are not.
- Critique the design, not the designer.
- No formal Code of Conduct is adopted at this scale. The steering
  committee, once formed under [§8](#8-the-catches-fire-trigger), is
  expected to adopt one as one of its first artefacts.

## 11. Amendments to this document

This document is itself amended via the RFC process. Amendments require a
meta-RFC with `applies-to: governance` in the frontmatter. Until and unless
the [catches-fire trigger fires](#8-the-catches-fire-trigger), the BDFL has
final say on amendments, the same authority that applies to any other RFC.

After the trigger fires, amendments require steering-committee approval;
design-invariant changes additionally require the Lead Architect's
non-veto.

## Appendix A — design captured before this process

The current design corpus predates this process: `DESIGN.md`, the
`docs/design/` elaborations (`wire-format.md`, `looper-framework.md`,
`toolkit.md`, `window-management.md`, `api-evolution.md`, and the rest), the
`docs/interfaces/*.md` schemas, and the registers (`acceleration.md`,
`TECH-DEBT.md`, `public-api.md`, `dependency-allowlist.md`). These are the
captured design, folded in directly, and they are the baseline every future
RFC is measured against.

Future RFCs follow this document: they live in `rfcs/RFC-NNNN-*.md` until
accepted and implemented, then either continue to live there with status
`implemented` or `stabilised`, or get folded into the relevant design doc
with a forward-pointer left behind in the RFC file.

## Appendix B — acknowledgements

This process draws ideas from, in rough order of influence:

- **The Vestra governance process** — this document is adapted directly
  from it; the BDFL is the same person, and the lifecycle, the design-
  invariants section, and the catches-fire structure are inherited.
- **Swift Evolution** — the lifecycle structure, the "Accepted with
  revisions" mechanic, the stabilisation period.
- **Rust RFCs** — the per-RFC file pattern, the explicit Alternatives
  section, the public Discussion phase.
- **Python PEPs** — the metadata frontmatter, typed status values.
- **The FreeBSD core-team model** — the BDFL-flavoured posture with a small
  reviewed core, fitting for a project that sits on the FreeBSD base.
- **Zig** — the smaller-than-formal-standardisation posture, and
  specifically the willingness to remove features rather than ship them
  broken, which the epoch policy (`api-evolution.md`) is built to make
  routine.

## Appendix C — RFC template

Copy `rfcs/0000-template.md` to `rfcs/RFC-NNNN-your-name.md` and fill it in.
The template:

```markdown
---
rfc-id: RFC-NNNN
title: <short title>
status: draft
author: <your name>
shepherd: TBD
created: YYYY-MM-DD
last-updated: YYYY-MM-DD
applies-to: <bus | capabilities | interfaces | toolkit | compositor | broker | packaging | budgets | base-boundary | governance>
implementation: TBD
---

# RFC-NNNN: <title>

## Summary

<One paragraph. The whole proposal in 100 words.>

## Motivation

<Why is this worth doing? What bug class, friction, capability, or use case
does it address? Worked examples of the current pain are welcome. If this
revises a design invariant (§7), say so here, explicitly.>

## Design

<The proposal itself. Detailed enough that a competent engineer can
implement it. Message schemas, interface fragments, capability flows, API
signatures, whatever is load-bearing.>

## Examples

<At least one positive example showing idiomatic use. At least one negative
example showing what is rejected, and how: an Error value, a refused
capability, a decode failure.>

## Alternatives considered

### Alternative A: <name>

<Description, rejection rationale.>

### Alternative B: <name>

<Description, rejection rationale.>

## Costs and tradeoffs

- Surface area added:
- Learning curve:
- Implementation complexity:
- Budget impact (DESIGN.md §3.6):
- Interaction with other components:

## Backwards compatibility / migration

<What existing code or app bundles break? What is the migration story? Is
the change additive (no epoch bump) or subtractive (an epoch bump with the
deprecate-schedule-migrate obligation of api-evolution.md §6)?>

## Open questions

- <Question 1>
- <Question 2>

## Prior art (optional)

<Other systems, papers, precedents. BeOS, Haiku, FreeBSD especially.>

## Reference implementation (optional)

<Branch / PR pointer.>

## Spec text (optional)

<Pre-written prose for inclusion in the relevant design doc if accepted.>
```
