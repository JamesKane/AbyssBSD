// SPDX-License-Identifier: BSD-2-Clause

//! Capability rights as compile-time phantom typestate
//! (`docs/design/looper-framework.md` §7.2).
//!
//! **Honest caveat.** These types are *intra-process compile-time hygiene
//! only* — they keep a component honest with itself. They do **not**
//! secure a process boundary: one process cannot trust another's compiler.
//! Real enforcement is the kernel (`cap_rights_t`) and the exporting
//! service's runtime check — Phase 4, Gate D.

/// A marker type denoting a set of object rights.
pub trait Rights: 'static {}

/// `Self` is a subset of the rights set `Whole` — narrowing `Whole` down
/// to `Self` is sound.
///
/// [`Cap::narrow`](crate::Cap::narrow) carries a `R2: SubsetOf<R>` bound,
/// so a `narrow` that would *widen* fails to compile.
pub trait SubsetOf<Whole: Rights>: Rights {}

/// Every rights set is a subset of itself — `narrow` to the same rights is
/// always allowed.
impl<R: Rights> SubsetOf<R> for R {}
