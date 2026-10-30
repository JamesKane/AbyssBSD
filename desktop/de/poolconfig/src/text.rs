//! What Config.parse does with Swift's Characters, done on a `str`.
//!
//! Swift splits, trims and looks for `[`, `]`, `=`, `#` and `;` by
//! Character, an extended grapheme cluster compared by canonical
//! equivalence, so a delimiter only counts when it stands alone:
//!
//! - `"\r\n"` is one Character, and not `"\n"`: a CRLF never ends a line,
//!   nor is it trimmed. A lone `"\r"` or `"\n"` is a Character of its own.
//! - A printable ASCII character followed by a combining mark, a joiner or
//!   a spacing mark (`EXTEND`), or preceded by a Prepend (`PREPEND`), is
//!   part of a bigger Character, and is not itself.
//! - U+037E GREEK QUESTION MARK is canonically `;`, so it starts a comment.
//!
//! Tabs, CR and LF are controls, which never join anything but CR LF.
//! These rules, with the two tables from the Swift runtime, make every
//! boundary below Swift's.

use crate::graphemes::{extends, prepends};

/// `s.split(separator: "\n", omittingEmptySubsequences: false)` on a
/// Swift String: at every `\n` that is not the end of a `\r\n`.
pub(crate) fn lines(s: &str) -> Vec<&str> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut start = 0;
    for i in 0..b.len() {
        if b[i] == b'\n' && (i == 0 || b[i - 1] != b'\r') {
            out.push(&s[start..i]);
            start = i + 1;
        }
    }
    out.push(&s[start..]);
    out
}

fn next_char(s: &str, at: usize) -> Option<char> {
    s[at..].chars().next()
}

fn prev_char(s: &str, at: usize) -> Option<char> {
    s[..at].chars().next_back()
}

/// The printable ASCII byte at `i` is a Character by itself.
fn alone(s: &str, i: usize) -> bool {
    !next_char(s, i + 1).is_some_and(extends) && !prev_char(s, i).is_some_and(prepends)
}

/// `trimmedPool()`: drop the Characters " ", "\t", "\r" and "\n" from both
/// ends.
pub(crate) fn trim(s: &str) -> &str {
    let mut s = s;
    loop {
        let b = s.as_bytes();
        let drop = match b.first() {
            Some(b'\t') | Some(b'\n') => true,
            Some(b'\r') => b.get(1) != Some(&b'\n'),
            Some(b' ') => alone(s, 0),
            _ => false,
        };
        if !drop {
            break;
        }
        s = &s[1..];
    }
    loop {
        let b = s.as_bytes();
        let n = b.len();
        let drop = match b.last() {
            Some(b'\t') | Some(b'\r') => true,
            Some(b'\n') => n < 2 || b[n - 2] != b'\r',
            Some(b' ') => alone(s, n - 1),
            _ => false,
        };
        if !drop {
            break;
        }
        s = &s[..n - 1];
    }
    s
}

/// `s.hasPrefix(String(c))` for a printable ASCII `c`.
pub(crate) fn starts_with(s: &str, c: u8) -> bool {
    s.as_bytes().first() == Some(&c) && alone(s, 0)
}

/// `s.hasPrefix(";")`: also U+037E, its canonical equivalent.
pub(crate) fn starts_with_semicolon(s: &str) -> bool {
    starts_with(s, b';') || (s.starts_with('\u{37E}') && !next_char(s, 2).is_some_and(extends))
}

/// `s.hasSuffix(String(c))` for a printable ASCII `c`.
pub(crate) fn ends_with(s: &str, c: u8) -> bool {
    s.as_bytes().last() == Some(&c) && alone(s, s.len() - 1)
}

/// `s.firstIndex(of: Character(c))` for a printable ASCII `c`, as a byte
/// offset.
pub(crate) fn find(s: &str, c: u8) -> Option<usize> {
    s.bytes().enumerate().find(|&(i, b)| b == c && alone(s, i)).map(|(i, _)| i)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crlf_is_one_character() {
        assert_eq!(lines("a\r\nb\nc"), ["a\r\nb", "c"]);
        assert_eq!(lines("\n\r\n\n"), ["", "\r\n", ""]);
        assert_eq!(lines("a\rb"), ["a\rb"]);
        assert_eq!(trim("\r\nx\r\n"), "\r\nx\r\n");
        assert_eq!(trim("\r\r\nx\r\r"), "\r\nx");
        assert_eq!(trim(" \t\rx \n"), "x");
    }

    #[test]
    fn a_combining_mark_takes_the_delimiter_with_it() {
        assert_eq!(trim(" \u{301}k "), " \u{301}k");
        assert_eq!(trim("\t\u{301}k"), "\u{301}k");
        assert_eq!(trim("k\u{600} "), "k\u{600} ");
        assert!(!starts_with("[\u{301}x]", b'['));
        assert!(!ends_with("[x\u{600}]", b']'));
        assert!(ends_with("[x]", b']'));
        assert_eq!(find("a=\u{338}b=c", b'='), Some(5));
        assert_eq!(find("a\u{600}=b", b'='), None);
        assert!(starts_with_semicolon("\u{37E} x"));
        assert!(!starts_with_semicolon("\u{37E}\u{301}"));
        assert!(!starts_with("#\u{FE0F}\u{20E3}", b'#'));
    }
}
