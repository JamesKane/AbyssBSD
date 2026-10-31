//! The VT parser and the screen model with no pty and no display
//! (TerminalTests.swift): each feeds bytes a real program sends and asserts
//! on what the screen then holds.

use crate::keys::{encode, sym, KeyMods};
use crate::parser::{VtAction, VtParser};
use crate::screen::{CellAttributes, Screen, TermColor};
use crate::selection::{paste_bytes, TextPoint};

fn screen(rows: usize, cols: usize, s: &str) -> Screen {
    let mut sc = Screen::new(rows, cols);
    sc.feed_str(s);
    sc
}

fn csi(params: &[i64], private: Option<u8>, f: u8) -> VtAction {
    VtAction::Csi { params: params.to_vec(), intermediates: vec![], private, final_byte: f }
}

// The parser

#[test]
fn the_parser_splits_text_controls_and_sequences() {
    let mut got = vec![];
    VtParser::new().feed("a\r\x1b[?1049h\x1b[1;31m\x1b7\x1b]0;hi\x07é".as_bytes(), &mut |a| got.push(a));
    assert_eq!(got, [VtAction::Print('a'), VtAction::Execute(0x0D), csi(&[1049], Some(b'?'), b'h'), csi(&[1, 31], None, b'm'), VtAction::Esc { intermediates: vec![], final_byte: b'7' }, VtAction::Osc("0;hi".into()), VtAction::Print('é')]);
}

/// A sequence split across reads, the ordinary case on a pty, parses the
/// same as one that arrives whole.
#[test]
fn a_sequence_split_across_reads_is_the_same_sequence() {
    let bytes = "x\x1b[12;34Hé\x1b]2;t\x1b\\".as_bytes();
    let (mut a, mut b) = (vec![], vec![]);
    VtParser::new().feed(bytes, &mut |x| a.push(x));
    let mut split = VtParser::new();
    for &byte in bytes {
        split.step(byte, &mut |x| b.push(x))
    }
    assert_eq!(a, b);
    assert_eq!(a.last(), Some(&VtAction::Osc("2;t".into())), "ST (ESC \\) ends an OSC as BEL does");
}

/// A control byte inside a broken rune: U+FFFD for the rune, and the
/// control still acts.
#[test]
fn broken_utf8_becomes_replacement_and_controls_still_act() {
    let mut sc = Screen::new(2, 10);
    sc.feed(&[0x61, 0xC3, 0x1B, 0x5B, 0x32, 0x43, 0x62]); // a, half of é, ESC [ 2 C, b
    assert_eq!(sc.text_row(0), "a\u{FFFD}  b");
}

// Text and wrapping

#[test]
fn printing_wraps_only_when_the_next_character_arrives() {
    let mut sc = screen(3, 5, "abcde");
    assert_eq!((sc.cursor_row(), sc.cursor_col()), (0, 4), "the last column sets a pending wrap, not a new line");
    sc.feed_str("f");
    assert_eq!(sc.lines(), ["abcde", "f", ""]);
    assert_eq!(screen(2, 5, "\x1b[?7labcdefg").lines(), ["abcdg", ""], "autowrap off: the last column is overwritten");
}

#[test]
fn controls_move_the_cursor_as_a_terminal_does() {
    assert_eq!(screen(3, 20, "ab\x08X\tY\r\nZ").lines(), ["aX      Y", "Z", ""]);
}

#[test]
fn the_screen_scrolls_into_scrollback_at_the_bottom() {
    let sc = screen(3, 10, "1\r\n2\r\n3\r\n4\r\n5");
    assert_eq!(sc.lines(), ["3", "4", "5"]);
    assert_eq!(sc.scrollback().len(), 2);
    assert_eq!(sc.scrollback()[0].iter().map(|c| c.ch).collect::<String>().trim(), "1");
}

// Cursor, erase, edit

#[test]
fn cursor_addressing_and_erasing() {
    let mut sc = screen(4, 10, "xxxxxxxxxx\r\nyyyyyyyyyy\r\nzzzzzzzzzz");
    sc.feed_str("\x1b[2;4H\x1b[K");
    assert_eq!(sc.lines()[1], "yyy");
    sc.feed_str("\x1b[1;3H\x1b[1K");
    assert_eq!(sc.lines()[0], "   xxxxxxx");
    sc.feed_str("\x1b[3;5H\x1b[J");
    assert_eq!(sc.lines(), ["   xxxxxxx", "yyy", "zzzz", ""]);
    sc.feed_str("\x1b[H\x1b[2J");
    assert_eq!(sc.lines(), ["", "", "", ""]);
    assert_eq!(sc.cursor_row(), 0);
}

#[test]
fn insert_and_delete_characters_and_lines() {
    let mut sc = screen(4, 8, "abcdef\r\nline2\r\nline3\r\nline4");
    sc.feed_str("\x1b[1;3H\x1b[2@");
    assert_eq!(sc.lines()[0], "ab  cdef");
    sc.feed_str("\x1b[3P");
    assert_eq!(sc.lines()[0], "abdef");
    sc.feed_str("\x1b[2;1H\x1b[L");
    assert_eq!(sc.lines(), ["abdef", "", "line2", "line3"]);
    sc.feed_str("\x1b[M\x1b[M");
    assert_eq!(sc.lines(), ["abdef", "line3", "", ""]);
    assert!(sc.scrollback().is_empty(), "deleting lines is not history");
    sc.feed_str("\x1b[1;2H\x1b[2X");
    assert_eq!(sc.lines()[0], "a  ef");
}

/// `rep`: CSI b repeats the last character, how ncurses 6 draws a rule.
#[test]
fn repeat_prints_the_last_character_again() {
    assert_eq!(screen(1, 10, "-\x1b[5b").lines(), ["------"]);
}

// Scroll regions, as vi and less use them

#[test]
fn a_scroll_region_scrolls_only_its_lines() {
    let mut sc = screen(5, 10, "top\r\na\r\nb\r\nc\r\nstatus");
    sc.feed_str("\x1b[2;4r");
    assert_eq!(sc.cursor_row(), 0, "setting a region homes the cursor");
    sc.feed_str("\x1b[4;1H\nnew");
    assert_eq!(sc.lines(), ["top", "b", "c", "new", "status"]);
    assert!(sc.scrollback().is_empty(), "a region's lines are not history");
    sc.feed_str("\x1b[2;1H\x1bM"); // RI at the region's top
    assert_eq!(sc.lines(), ["top", "", "b", "c", "status"]);
}

// The alternate screen

#[test]
fn the_alternate_screen_is_left_as_it_was_found() {
    let mut sc = screen(3, 10, "$ vi\r\n");
    sc.feed_str("\x1b[?1049h\x1b[22;0;0t\x1b[H\x1b[2Jfile text\x1b[3;1H~");
    assert!(sc.using_alternate());
    assert_eq!(sc.lines(), ["file text", "", "~"]);
    sc.feed_str("\x1b[?1049l\x1b[23;0;0t");
    assert!(!sc.using_alternate());
    assert_eq!(sc.lines(), ["$ vi", "", ""]);
    assert_eq!(sc.cursor_row(), 1, "and the cursor where it was");
}

// Attributes

#[test]
fn sgr_sets_the_pen_and_erasing_uses_its_background() {
    let mut sc = screen(2, 10, "\x1b[1;4;31;42mA\x1b[0mB\x1b[38;5;200;48;2;1;2;3mC\x1b[m");
    let a = sc.cell(0, 0).attrs;
    assert!(a.bold && a.underline);
    assert_eq!((a.fg, a.bg), (TermColor::Indexed(1), TermColor::Indexed(2)));
    assert_eq!(sc.cell(0, 1).attrs, CellAttributes::default(), "SGR 0 resets everything");
    assert_eq!(sc.cell(0, 2).attrs.fg, TermColor::Indexed(200));
    assert_eq!(sc.cell(0, 2).attrs.bg, TermColor::Rgb(1, 2, 3));
    sc.feed_str("\x1b[44m\x1b[2;1H\x1b[K");
    assert_eq!(sc.cell(1, 5).attrs.bg, TermColor::Indexed(4), "bce: erase takes the pen's background");
    assert!(!sc.cell(1, 5).attrs.bold);
}

#[test]
fn line_drawing_characters_from_the_dec_set() {
    assert_eq!(screen(1, 10, "\x1b(0lqqk\x1b(Bx").lines(), ["┌──┐x"]);
}

// Talking back

#[test]
fn the_terminal_answers_where_its_cursor_is_and_what_it_is() {
    let mut sc = screen(5, 10, "\x1b[3;7H\x1b[6n\x1b[c");
    assert_eq!(sc.responses, b"\x1b[3;7R\x1b[?1;2c");
    sc.responses.clear();
    sc.feed_str("\x1b[>c");
    assert_eq!(sc.responses, b"\x1b[>0;95;0c");
}

#[test]
fn modes_and_the_title() {
    let mut sc = screen(2, 10, "\x1b[?1h\x1b=\x1b[?25l\x1b[?2004h\x1b]2;vi file\x07");
    assert!(sc.application_cursor_keys() && sc.application_keypad() && sc.bracketed_paste());
    assert!(!sc.cursor_visible());
    assert_eq!(sc.title(), "vi file");
    sc.feed_str("\x1b[!p"); // DECSTR: FreeBSD termcap's `is`
    assert!(!sc.application_cursor_keys());
    assert!(sc.cursor_visible());
}

// Size

#[test]
fn resizing_keeps_the_cursors_line_in_view() {
    let mut sc = screen(4, 10, "1\r\n2\r\n3\r\n4");
    sc.resize(2, 5);
    assert_eq!(sc.lines(), ["3", "4"]);
    assert_eq!(sc.cursor_row(), 1);
    assert_eq!(sc.scrollback().len(), 2, "what no longer fits above the cursor is history");
    sc.resize(3, 12);
    assert_eq!(sc.lines(), ["3", "4", ""]);
    assert_eq!(sc.cols(), 12);
}

// Keys (P15.4b)

fn key(s: u32, text: &str, m: KeyMods, app: bool) -> String {
    String::from_utf8(encode(s, text, m, app)).unwrap()
}
const NONE: KeyMods = KeyMods { shift: false, option: false, control: false };
const CTRL: KeyMods = KeyMods { control: true, ..NONE };
const SHIFT: KeyMods = KeyMods { shift: true, ..NONE };

#[test]
fn keys_become_what_xterm_sends() {
    assert_eq!(key(0x61, "a", NONE, false), "a");
    assert_eq!(key(0xe9, "é", NONE, false), "é");
    assert_eq!(key(0x63, "c", CTRL, false), "\x03", "Ctrl-C is ETX");
    assert_eq!(key(0x63, "", CTRL, false), "\x03", "and still ETX when the toolkit gives no text");
    assert_eq!(key(0x5b, "[", CTRL, false), "\x1b", "Ctrl-[ is ESC");
    assert_eq!(key(0x62, "b", KeyMods { option: true, ..NONE }, false), "\x1bb", "Option is Meta");
    assert_eq!(key(sym::BACKSPACE, "", NONE, false), "\x7f");
    assert_eq!(key(sym::ENTER, "", NONE, false), "\r");
    assert_eq!(key(sym::TAB, "", SHIFT, false), "\x1b[Z");
    assert_eq!(key(sym::ESCAPE, "", NONE, false), "\x1b");
    assert_eq!(key(0xffe1, "", NONE, false), "", "a modifier on its own sends nothing");
}

/// DECCKM: vi and less ask for application cursor keys, and get SS3.
#[test]
fn cursor_keys_follow_the_programs_mode() {
    assert_eq!(key(sym::UP, "", NONE, false), "\x1b[A");
    assert_eq!(key(sym::UP, "", NONE, true), "\x1bOA");
    assert_eq!(key(sym::RIGHT, "", CTRL, false), "\x1b[1;5C", "xterm's modified cursor key");
    assert_eq!(key(sym::HOME, "", NONE, false), "\x1b[H");
    assert_eq!(key(sym::PAGE_DOWN, "", NONE, false), "\x1b[6~");
    assert_eq!(key(sym::DELETE, "", NONE, false), "\x1b[3~");
    assert_eq!(key(sym::F1, "", NONE, false), "\x1bOP");
    assert_eq!(key(sym::F1 + 4, "", NONE, false), "\x1b[15~", "F5");
    assert_eq!(key(sym::F1 + 11, "", SHIFT, false), "\x1b[24;2~", "Shift-F12");
}

// Selection, scrollback, paste (P15.4c)

/// A line longer than the terminal wraps; copied, it is one line again,
/// and a line that ended in a newline keeps it, without trailing spaces.
#[test]
fn a_copied_wrapped_line_is_one_line() {
    let sc = screen(4, 10, "abcdefghijKLMNO\r\nnext   \r\n");
    assert_eq!(sc.lines(), ["abcdefghij", "KLMNO", "next", ""]);
    assert!(sc.cell(0, 9).wraps_to_next);
    assert!(!sc.cell(1, 9).wraps_to_next);
    assert_eq!(sc.text_between(TextPoint::new(0, 0), TextPoint::new(2, 9)), "abcdefghijKLMNO\nnext");
    assert_eq!(sc.text_between(TextPoint::new(1, 3), TextPoint::new(0, 8)), "ijKLMN", "either order; inside a wrapped line");
}

#[test]
fn selection_reaches_into_scrollback() {
    let mut sc = screen(2, 8, "one\r\ntwo\r\nthree\r\nfour");
    assert_eq!(sc.total_lines(), 4);
    assert_eq!(sc.text_between(TextPoint::new(0, 0), TextPoint::new(3, 7)), "one\ntwo\nthree\nfour");
    sc.clear_scrollback();
    assert_eq!(sc.total_lines(), 2);
    assert_eq!(sc.lines(), ["three", "four"], "clearing history leaves the screen");
}

#[test]
fn double_and_triple_click_ranges() {
    let sc = screen(2, 30, "ls /usr/local/bin; echo ok");
    let (a, b) = sc.word_range(TextPoint::new(0, 8));
    assert_eq!(sc.text_between(a, b), "/usr/local/bin", "a path is one word");
    let (c, d) = sc.word_range(TextPoint::new(0, 17));
    assert_eq!(c, d, "a semicolon is a word of its own");
    let (e, f) = sc.line_range(TextPoint::new(0, 3));
    assert_eq!(sc.text_between(e, f), "ls /usr/local/bin; echo ok");
}

#[test]
fn paste_is_returns_and_bracketed_when_asked() {
    assert_eq!(paste_bytes("a\nb\r\nc", false), b"a\rb\rc");
    assert_eq!(paste_bytes("ls\n", true), b"\x1b[200~ls\r\x1b[201~");
    assert_eq!(paste_bytes("x\x1b[201~rm -rf ~\n", true), b"\x1b[200~xrm -rf ~\r\x1b[201~", "an end marker inside cannot end the bracket");
}
