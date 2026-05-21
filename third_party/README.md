# third_party

Pinned external source the AbyssBSD build depends on.

## freebsd-src — the FreeBSD base

A git submodule pinning the FreeBSD source tree AbyssBSD builds and curates
against (see [`../docs/ROADMAP.md`](../docs/ROADMAP.md) §1 and §6).

- **Pin:** branch `releng/15.0`, commit `6d536196` —
  **FreeBSD 15.0-RELEASE-p9**.
- **Upstream:** <https://git.freebsd.org/src.git>

### Populating it

The submodule is **committed but not populated** — nothing before Phase 4
(ROADMAP §4) needs the FreeBSD source, and a full checkout is multi-GB.
Populate it when Phase 4 begins:

```sh
git submodule update --init --filter=tree:0 third_party/freebsd-src
```

`--filter=tree:0` makes it a treeless partial clone — small, but with full
commit history retained so the pin can advance without a re-clone.

### Advancing the pin

AbyssBSD follows the FreeBSD dot cycle (ROADMAP §1) — one errata level or
dot release at a time, each a deliberate step:

```sh
cd third_party/freebsd-src
git fetch origin releng/15.0          # errata; or: git fetch origin releng/15.1
git checkout <new-commit-or-branch>
cd ../..
git add third_party/freebsd-src       # records the new pin
```

Then update the pin facts above, in `.gitmodules` (the `branch` line, on a
dot-release bump), and in ROADMAP §6.

> The sibling checkout `../../freebsd-src` is unrelated — a general
> `main`/16.0-CURRENT working copy, never the project's pin.
