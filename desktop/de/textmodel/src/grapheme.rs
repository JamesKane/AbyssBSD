//! Extended grapheme clusters (UAX #29): what a person calls one character,
//! and what Swift calls a `Character`. A caret never lands inside one.
//!
//! The rules are UAX #29's, GB3 to GB999; the properties are generated from
//! the Unicode Character Database (gen-graphemes.py), and the conformance
//! test is the UCD's own GraphemeBreakTest.txt (tests/graphemes.rs).

use crate::grapheme_tables::TABLE;

const OTHER: u8 = 0;
const CR: u8 = 1;
const LF: u8 = 2;
const CONTROL: u8 = 3;
const EXTEND: u8 = 4;
const ZWJ: u8 = 5;
const RI: u8 = 6;
const PREPEND: u8 = 7;
const SPACING_MARK: u8 = 8;
const L: u8 = 9;
const V: u8 = 10;
const T: u8 = 11;
const LV: u8 = 12;
const LVT: u8 = 13;

const EXT_PICT: u8 = 0x10;
const INCB_CONSONANT: u8 = 0x20;
const INCB_LINKER: u8 = 0x40;
const INCB_EXTEND: u8 = 0x80;

fn property(c: char) -> u8 {
    let c = c as u32;
    match TABLE.binary_search_by(|&(lo, hi, _)| if hi < c { std::cmp::Ordering::Less } else if lo > c { std::cmp::Ordering::Greater } else { std::cmp::Ordering::Equal }) {
        Ok(i) => TABLE[i].2,
        Err(_) => OTHER,
    }
}

/// What the text so far ends with, for the rules that look back further
/// than one character.
#[derive(Default)]
struct State {
    /// ExtPict Extend* (GB11's start).
    pict: bool,
    /// ExtPict Extend* ZWJ: GB11 joins the next ExtPict.
    pict_zwj: bool,
    /// InCB=Linker InCB=Extend*: GB9c joins the next InCB=Consonant
    /// (Unicode 18's rule; before it, a Consonant had to come first).
    linked: bool,
    /// How many Regional_Indicators in a row (GB12, GB13: pairs).
    ri: usize,
}

impl State {
    fn push(&mut self, p: u8) {
        let gcb = p & 0x0f;
        self.pict_zwj = gcb == ZWJ && self.pict;
        self.pict = p & EXT_PICT != 0 || (gcb == EXTEND && self.pict);
        self.linked = p & INCB_LINKER != 0 || (self.linked && p & INCB_EXTEND != 0);
        self.ri = if gcb == RI { self.ri + 1 } else { 0 };
    }

    /// Whether there is a boundary between the text so far, ending in
    /// `prev`, and `cur`.
    fn breaks(&self, prev: u8, cur: u8) -> bool {
        let (a, b) = (prev & 0x0f, cur & 0x0f);
        match (a, b) {
            (CR, LF) => false,                                         // GB3
            (CONTROL | CR | LF, _) | (_, CONTROL | CR | LF) => true,   // GB4, GB5
            (L, L | V | LV | LVT) | (LV | V, V | T) | (LVT | T, T) => false, // GB6-8
            (_, EXTEND | ZWJ | SPACING_MARK) | (PREPEND, _) => false,  // GB9-9b
            _ if cur & INCB_CONSONANT != 0 && self.linked => false,    // GB9c
            (ZWJ, _) if cur & EXT_PICT != 0 && self.pict_zwj => false, // GB11
            (RI, RI) => self.ri.is_multiple_of(2),                             // GB12, GB13
            _ => true,                                                 // GB999
        }
    }
}

/// The clusters of `s`, in order.
pub fn clusters(s: &str) -> Clusters<'_> {
    Clusters { s, pos: 0 }
}

pub struct Clusters<'a> {
    s: &'a str,
    pos: usize,
}

impl<'a> Iterator for Clusters<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<&'a str> {
        let rest = &self.s[self.pos..];
        let mut chars = rest.char_indices();
        let (_, first) = chars.next()?;
        let mut state = State::default();
        let mut prev = property(first);
        state.push(prev);
        let mut end = rest.len();
        for (i, c) in chars {
            let p = property(c);
            if state.breaks(prev, p) {
                end = i;
                break;
            }
            state.push(p);
            prev = p;
        }
        self.pos += end;
        Some(&rest[..end])
    }
}
