// SPDX-License-Identifier: BSD-2-Clause

//! Capability rights as compile-time typestate, with the runtime mask the
//! typestate stands for (`docs/design/broker-and-transport.md` §3.3,
//! `docs/design/looper-framework.md` §7.2).
//!
//! A type implementing [`Rights`] is one form of an object-rights mask;
//! the `u32` is the other. Every [`Cap`](crate::Cap) carries that mask in
//! a runtime field set, at construction, to `R::MASK`;
//! [`narrow`](crate::Cap::narrow) ANDs it, [`bind`](crate::Cap::bind)
//! checks an arrived mask is no wider than the receiving `R::MASK` — a
//! `Cap` claiming more authority than its type asserts is rejected at the
//! seam. The kernel (`cap_rights_t`) and the exporting service's runtime
//! check stay the source of truth across a process boundary; the
//! typestate is the client-side compile-time counterpart.

/// A set of object rights — a typestate that stands for a runtime mask.
///
/// A *class* (`recv`, `present`) is a Rust type whose [`MASK`](Rights::MASK)
/// is the bitmask of the method ordinals the class covers; a *union* of
/// classes is a type whose `MASK` is the OR of theirs. The interface
/// author defines them alongside `#[derive(Method)]`.
pub trait Rights: 'static {
    /// The object-rights mask this typestate stands for — a bitmask over
    /// the interface's method ordinals
    /// (`broker-and-transport.md` §3.3, §2.9).
    const MASK: u32;
}

/// `Self` is a subset of the rights set `Whole` — narrowing `Whole` down
/// to `Self` is sound.
///
/// [`Cap::narrow`](crate::Cap::narrow) carries a `R2: SubsetOf<R>` bound,
/// so a `narrow` that would *widen* fails to compile.
pub trait SubsetOf<Whole: Rights>: Rights {}

/// Every rights set is a subset of itself — `narrow` to the same rights is
/// always allowed.
impl<R: Rights> SubsetOf<R> for R {}
