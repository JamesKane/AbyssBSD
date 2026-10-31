//! What a terminal shows, and what a program's output does to it
//! (Screen.swift, P15.4a): a grid of cells, a cursor and its pen, a scroll
//! region, the modes a program sets, and the alternate screen full-screen
//! programs draw on and leave.
//!
//! **The subset is xterm's, as `TERM=xterm` uses it**, read off its
//! terminfo entry: `smcup` is `CSI ?1049h`, `rep` is `CSI Ps b`, `csr` sets
//! a scroll region, colours are SGR 30–37/40–47 plus 256 and direct colour.
//! Erase takes the pen's background (`bce`). Not here: double-width
//! characters (every scalar is one column), combining marks, mouse
//! reporting, double-height lines, 132 columns: each ignored, not misdrawn.

use crate::parser::{VtAction, VtParser};
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum TermColor {
    #[default]
    Default,
    /// 0–15 the palette, 16–255 xterm's cube and greys.
    Indexed(u8),
    Rgb(u8, u8, u8),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub struct CellAttributes {
    pub fg: TermColor,
    pub bg: TermColor,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub blink: bool,
    pub inverse: bool,
    pub invisible: bool,
    pub strike: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cell {
    pub ch: char,
    pub attrs: CellAttributes,
    /// On a row's last cell: the text went on because it did not fit, not
    /// because of a newline. Kept in the cell so every line move carries it,
    /// and erasing or overwriting the cell clears it, as xterm's flag does.
    pub wraps_to_next: bool,
}

impl Default for Cell {
    fn default() -> Cell {
        Cell::new(' ', CellAttributes::default())
    }
}

impl Cell {
    pub fn new(ch: char, attrs: CellAttributes) -> Cell {
        Cell { ch, attrs, wraps_to_next: false }
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Saved {
    row: usize,
    col: usize,
    pen: CellAttributes,
    origin_mode: bool,
    autowrap: bool,
    g0_graphics: bool,
    g1_graphics: bool,
    shifted: bool,
}

impl Saved {
    fn initial() -> Saved {
        Saved { autowrap: true, ..Saved::default() }
    }
}

#[derive(Clone, Debug)]
pub struct Screen {
    rows: usize,
    cols: usize,
    cursor_row: usize,
    cursor_col: usize,
    /// What the next character is drawn with.
    pen: CellAttributes,
    autowrap: bool,
    origin_mode: bool,
    insert_mode: bool,
    cursor_visible: bool,
    /// DECCKM: arrows send `ESC O A`, not `ESC [ A`; vi and less ask.
    application_cursor_keys: bool,
    application_keypad: bool,
    bracketed_paste: bool,
    using_alternate: bool,
    scroll_top: usize,
    scroll_bottom: usize,
    title: String,
    bells: u64,
    /// Lines scrolled off the top of the main screen, oldest first. Never
    /// the alternate screen's: vi scrolling is not history.
    pub(crate) scrollback: Vec<Vec<Cell>>,
    pub scrollback_limit: usize,
    /// What the terminal must say back: the replies to `CSI 6n` and
    /// `CSI c`. The owner writes them to the pty and clears this.
    pub responses: Vec<u8>,
    main: Vec<Vec<Cell>>,
    alternate: Vec<Vec<Cell>>,
    /// Set by printing in the last column: the *next* character wraps.
    /// xterm's rule, the difference between a status line that fits and
    /// one that scrolls the screen.
    pending_wrap: bool,
    tab_stops: BTreeSet<usize>,
    saved: Saved,
    saved_alternate: Saved,
    /// G0 and G1: DEC special graphics or ASCII; SO selects G1.
    g0_graphics: bool,
    g1_graphics: bool,
    shifted: bool,
    last_printed: char,
    parser: VtParser,
}

fn blank(r: usize, c: usize) -> Vec<Vec<Cell>> {
    vec![vec![Cell::default(); c]; r]
}

impl Screen {
    pub fn new(rows: usize, cols: usize) -> Screen {
        let (rows, cols) = (rows.max(1), cols.max(1));
        let mut s = Screen {
            rows,
            cols,
            cursor_row: 0,
            cursor_col: 0,
            pen: CellAttributes::default(),
            autowrap: true,
            origin_mode: false,
            insert_mode: false,
            cursor_visible: true,
            application_cursor_keys: false,
            application_keypad: false,
            bracketed_paste: false,
            using_alternate: false,
            scroll_top: 0,
            scroll_bottom: rows - 1,
            title: String::new(),
            bells: 0,
            scrollback: vec![],
            scrollback_limit: 10_000,
            responses: vec![],
            main: blank(rows, cols),
            alternate: blank(rows, cols),
            pending_wrap: false,
            tab_stops: BTreeSet::new(),
            saved: Saved::initial(),
            saved_alternate: Saved::initial(),
            g0_graphics: false,
            g1_graphics: false,
            shifted: false,
            last_printed: ' ',
            parser: VtParser::new(),
        };
        s.reset_tabs();
        s
    }

    // MARK: reading it

    pub fn rows(&self) -> usize {
        self.rows
    }
    pub fn cols(&self) -> usize {
        self.cols
    }
    pub fn cursor_row(&self) -> usize {
        self.cursor_row
    }
    pub fn cursor_col(&self) -> usize {
        self.cursor_col
    }
    pub fn pen(&self) -> CellAttributes {
        self.pen
    }
    pub fn cursor_visible(&self) -> bool {
        self.cursor_visible
    }
    pub fn application_cursor_keys(&self) -> bool {
        self.application_cursor_keys
    }
    pub fn application_keypad(&self) -> bool {
        self.application_keypad
    }
    pub fn bracketed_paste(&self) -> bool {
        self.bracketed_paste
    }
    pub fn using_alternate(&self) -> bool {
        self.using_alternate
    }
    pub fn title(&self) -> &str {
        &self.title
    }
    /// How many times the program rang the bell.
    pub fn bells(&self) -> u64 {
        self.bells
    }
    pub fn scrollback(&self) -> &[Vec<Cell>] {
        &self.scrollback
    }

    pub fn grid(&self) -> &[Vec<Cell>] {
        if self.using_alternate { &self.alternate } else { &self.main }
    }

    /// Row `r` as text, trailing spaces trimmed.
    pub fn text_row(&self, r: usize) -> String {
        self.grid()[r].iter().map(|c| c.ch).collect::<String>().trim_end_matches(' ').to_string()
    }

    pub fn lines(&self) -> Vec<String> {
        (0..self.rows).map(|r| self.text_row(r)).collect()
    }

    pub fn cell(&self, r: usize, c: usize) -> Cell {
        self.grid()[r][c]
    }

    // MARK: feeding it

    pub fn feed(&mut self, bytes: &[u8]) {
        let mut actions = vec![];
        self.parser.feed(bytes, &mut |a| actions.push(a));
        for a in actions {
            self.apply(a)
        }
    }

    pub fn feed_str(&mut self, s: &str) {
        self.feed(s.as_bytes())
    }

    pub fn apply(&mut self, action: VtAction) {
        match action {
            VtAction::Print(c) => self.put(c),
            VtAction::Execute(b) => self.execute(b),
            VtAction::Csi { params, intermediates, private, final_byte } => self.csi(&params, &intermediates, private, final_byte),
            VtAction::Esc { intermediates, final_byte } => self.esc(&intermediates, final_byte),
            VtAction::Osc(s) => self.osc(&s),
        }
    }

    // MARK: size

    /// A new size, as the window gives it. Lines that no longer fit above
    /// the cursor go to scrollback (main screen), so the cursor's line stays.
    pub fn resize(&mut self, rows: usize, cols: usize) {
        let (nr, nc) = (rows.max(1), cols.max(1));
        if nr == self.rows && nc == self.cols {
            return;
        }
        let fit = |g: &mut Vec<Vec<Cell>>, cursor: &mut usize, history: &mut Option<&mut Vec<Vec<Cell>>>| {
            for line in g.iter_mut() {
                line.resize(nc, Cell::default())
            }
            if g.len() > nr {
                let excess = (g.len() - nr).min(cursor.saturating_sub(nr - 1));
                if excess > 0 {
                    let gone: Vec<Vec<Cell>> = g.drain(..excess).collect();
                    if let Some(h) = history.as_mut() {
                        h.extend(gone)
                    }
                    *cursor -= excess
                }
                g.truncate(nr)
            }
            while g.len() < nr {
                g.push(vec![Cell::default(); nc])
            }
        };
        let mut main_cursor = if self.using_alternate { self.saved.row } else { self.cursor_row };
        let mut alt_cursor = if self.using_alternate { self.cursor_row } else { 0 };
        let mut pushed = vec![];
        fit(&mut self.main, &mut main_cursor, &mut Some(&mut pushed));
        fit(&mut self.alternate, &mut alt_cursor, &mut None);
        self.push_scrollback(pushed);
        (self.rows, self.cols) = (nr, nc);
        if self.using_alternate {
            self.cursor_row = alt_cursor;
            self.saved.row = main_cursor.min(nr - 1)
        } else {
            self.cursor_row = main_cursor
        }
        self.cursor_row = self.cursor_row.min(nr - 1);
        self.cursor_col = self.cursor_col.min(nc - 1);
        (self.scroll_top, self.scroll_bottom) = (0, nr - 1);
        self.pending_wrap = false;
        self.reset_tabs()
    }

    // MARK: characters

    fn put(&mut self, ch: char) {
        let graphics = if self.shifted { self.g1_graphics } else { self.g0_graphics };
        let ch = if graphics { dec_graphics(ch).unwrap_or(ch) } else { ch };
        if self.pending_wrap && self.autowrap {
            let (r, last) = (self.cursor_row, self.cols - 1);
            self.grid_mut()[r][last].wraps_to_next = true;
            self.cursor_col = 0;
            self.line_feed()
        }
        self.pending_wrap = false;
        if self.insert_mode {
            let (b, c) = (Cell::new(' ', self.pen), self.cursor_col);
            let line = self.line_mut();
            line.insert(c, b);
            line.pop();
        }
        let (r, c, pen) = (self.cursor_row, self.cursor_col, self.pen);
        self.grid_mut()[r][c] = Cell::new(ch, pen);
        self.last_printed = ch;
        if self.cursor_col == self.cols - 1 {
            self.pending_wrap = self.autowrap
        } else {
            self.cursor_col += 1
        }
    }

    fn execute(&mut self, b: u8) {
        match b {
            0x07 => self.bells += 1,
            0x08 => {
                self.cursor_col = self.cursor_col.saturating_sub(1);
                self.pending_wrap = false
            }
            0x09 => self.tab(1),
            0x0A..=0x0C => self.line_feed(),
            0x0D => {
                self.cursor_col = 0;
                self.pending_wrap = false
            }
            0x0E => self.shifted = true,
            0x0F => self.shifted = false,
            _ => {}
        }
    }

    fn line_feed(&mut self) {
        self.pending_wrap = false;
        if self.cursor_row == self.scroll_bottom {
            self.scroll_up(1, true)
        } else if self.cursor_row < self.rows - 1 {
            self.cursor_row += 1
        }
    }

    fn reverse_index(&mut self) {
        self.pending_wrap = false;
        if self.cursor_row == self.scroll_top {
            self.scroll_down(1)
        } else if self.cursor_row > 0 {
            self.cursor_row -= 1
        }
    }

    fn tab(&mut self, n: usize) {
        self.pending_wrap = false;
        for _ in 0..n.max(1) {
            let mut c = self.cursor_col + 1;
            while c < self.cols - 1 && !self.tab_stops.contains(&c) {
                c += 1
            }
            self.cursor_col = c.min(self.cols - 1)
        }
    }

    fn back_tab(&mut self, n: usize) {
        self.pending_wrap = false;
        for _ in 0..n.max(1) {
            let mut c = self.cursor_col.saturating_sub(1);
            while c > 0 && !self.tab_stops.contains(&c) {
                c -= 1
            }
            self.cursor_col = c
        }
    }

    // MARK: scrolling

    /// Scroll the region up: its top lines leave (into scrollback when the
    /// region is the whole main screen and `history`), blanks enter at the
    /// bottom. DL passes `history: false`: it deletes, not scrolls away.
    fn scroll_up(&mut self, n: usize, history: bool) {
        let (top, bottom) = (self.scroll_top, self.scroll_bottom);
        let n = n.max(1).min(bottom - top + 1);
        let line = self.blank_line();
        let g = self.grid_mut();
        let gone: Vec<Vec<Cell>> = g.drain(top..top + n).collect();
        let at = bottom + 1 - n;
        g.splice(at..at, std::iter::repeat_n(line, n));
        if history && !self.using_alternate && top == 0 && bottom == self.rows - 1 {
            self.push_scrollback(gone)
        }
    }

    fn scroll_down(&mut self, n: usize) {
        let (top, bottom) = (self.scroll_top, self.scroll_bottom);
        let n = n.max(1).min(bottom - top + 1);
        let line = self.blank_line();
        let g = self.grid_mut();
        g.drain(bottom + 1 - n..=bottom);
        g.splice(top..top, std::iter::repeat_n(line, n));
    }

    fn push_scrollback(&mut self, lines: Vec<Vec<Cell>>) {
        self.scrollback.extend(lines);
        if self.scrollback.len() > self.scrollback_limit {
            let excess = self.scrollback.len() - self.scrollback_limit;
            self.scrollback.drain(..excess);
        }
    }

    // MARK: ESC

    fn esc(&mut self, inter: &[u8], f: u8) {
        match (inter.first(), f) {
            (None, b'7') => self.save_cursor(),
            (None, b'8') => self.restore_cursor(),
            (None, b'D') => self.line_feed(), // IND
            (None, b'E') => {
                // NEL
                self.cursor_col = 0;
                self.line_feed()
            }
            (None, b'M') => self.reverse_index(), // RI
            (None, b'H') => {
                self.tab_stops.insert(self.cursor_col); // HTS
            }
            (None, b'c') => {
                // RIS
                let limit = self.scrollback_limit;
                *self = Screen::new(self.rows, self.cols);
                self.scrollback_limit = limit
            }
            (None, b'=') => self.application_keypad = true,
            (None, b'>') => self.application_keypad = false,
            (Some(b'('), f) => self.g0_graphics = f == b'0',
            (Some(b')'), f) => self.g1_graphics = f == b'0',
            // DECALN: vttest's screen of E.
            (Some(b'#'), b'8') => {
                self.main = vec![vec![Cell::new('E', CellAttributes::default()); self.cols]; self.rows];
                if self.using_alternate {
                    self.alternate = self.main.clone()
                }
                (self.cursor_row, self.cursor_col) = (0, 0)
            }
            _ => {}
        }
    }

    fn save_cursor(&mut self) {
        let s = Saved { row: self.cursor_row, col: self.cursor_col, pen: self.pen, origin_mode: self.origin_mode, autowrap: self.autowrap, g0_graphics: self.g0_graphics, g1_graphics: self.g1_graphics, shifted: self.shifted };
        if self.using_alternate {
            self.saved_alternate = s
        } else {
            self.saved = s
        }
    }

    fn restore_cursor(&mut self) {
        let s = if self.using_alternate { self.saved_alternate } else { self.saved };
        self.cursor_row = s.row.min(self.rows - 1);
        self.cursor_col = s.col.min(self.cols - 1);
        (self.pen, self.origin_mode, self.autowrap) = (s.pen, s.origin_mode, s.autowrap);
        (self.g0_graphics, self.g1_graphics, self.shifted) = (s.g0_graphics, s.g1_graphics, s.shifted);
        self.pending_wrap = false
    }

    // MARK: OSC

    fn osc(&mut self, s: &str) {
        if let Some(("0" | "2", title)) = s.split_once(';') {
            self.title = title.into()
        }
    }

    // MARK: CSI

    fn csi(&mut self, p: &[i64], inter: &[u8], private: Option<u8>, f: u8) {
        // Parameter `i`, where 0 and absent both mean `def`: the ANSI rule.
        let arg = |i: usize, def: usize| p.get(i).copied().filter(|v| *v != 0).map_or(def, |v| v as usize);
        if private == Some(b'?') {
            match f {
                b'h' => p.iter().for_each(|m| self.set_private_mode(*m, true)),
                b'l' => p.iter().for_each(|m| self.set_private_mode(*m, false)),
                _ => {}
            }
            return;
        }
        if private == Some(b'>') {
            if f == b'c' {
                self.reply("\x1b[>0;95;0c") // secondary DA: an xterm
            }
            return;
        }
        // `! p`, DECSTR: FreeBSD termcap's `is`.
        if private.is_none() && inter == b"!" && f == b'p' {
            return self.soft_reset();
        }
        if private.is_some() || !inter.is_empty() {
            return; // DECSCUSR (" q") and the rest: ignored
        }
        let (row, col) = (self.cursor_row, self.cursor_col);
        match f {
            b'@' => self.insert_cells(arg(0, 1)),                                // ICH
            b'A' => self.move_up(arg(0, 1)),                                     // CUU
            b'B' | b'e' => self.move_down(arg(0, 1)),                            // CUD, VPR
            b'C' | b'a' => self.move_to(row as i64, (col + arg(0, 1)) as i64),   // CUF, HPR
            b'D' => self.move_to(row as i64, col as i64 - arg(0, 1) as i64),     // CUB
            b'E' => {
                // CNL
                self.move_down(arg(0, 1));
                self.cursor_col = 0
            }
            b'F' => {
                // CPL
                self.move_up(arg(0, 1));
                self.cursor_col = 0
            }
            b'G' | b'`' => self.move_to(row as i64, arg(0, 1) as i64 - 1),        // CHA, HPA
            b'H' | b'f' => self.cursor_position(arg(0, 1), arg(1, 1), false),    // CUP, HVP
            b'I' => self.tab(arg(0, 1)),                                         // CHT
            b'J' => self.erase_display(arg(0, 0)),                               // ED
            b'K' => self.erase_line(arg(0, 0)),                                  // EL
            b'L' => self.insert_lines(arg(0, 1)),                                // IL
            b'M' => self.delete_lines(arg(0, 1)),                                // DL
            b'P' => self.delete_cells(arg(0, 1)),                                // DCH
            b'S' => self.scroll_up(arg(0, 1), true),                             // SU
            b'T' => self.scroll_down(arg(0, 1)),                                 // SD
            b'X' => self.erase_cells(arg(0, 1)),                                 // ECH
            b'Z' => self.back_tab(arg(0, 1)),                                    // CBT
            b'b' => {
                // REP
                for _ in 0..arg(0, 1).min(self.rows * self.cols) {
                    self.put(self.last_printed)
                }
            }
            b'c' if arg(0, 0) == 0 => self.reply("\x1b[?1;2c"), // DA: a VT100 with AVO
            b'd' => self.cursor_position(arg(0, 1), col + 1, true), // VPA
            b'g' => match arg(0, 0) {
                // TBC
                0 => {
                    self.tab_stops.remove(&col);
                }
                3 => self.tab_stops.clear(),
                _ => {}
            },
            b'h' if p.contains(&4) => self.insert_mode = true, // SM (IRM)
            b'l' if p.contains(&4) => self.insert_mode = false, // RM
            b'm' => self.sgr(p),
            b'n' => match arg(0, 0) {
                // DSR
                5 => self.reply("\x1b[0n"),
                6 => {
                    let r = if self.origin_mode { row - self.scroll_top } else { row };
                    self.reply(&format!("\x1b[{};{}R", r + 1, col + 1))
                }
                _ => {}
            },
            b'r' => {
                // DECSTBM
                let (top, bottom) = (arg(0, 1) - 1, arg(1, self.rows) - 1);
                if top < bottom && bottom < self.rows {
                    (self.scroll_top, self.scroll_bottom) = (top, bottom);
                    self.cursor_position(1, 1, false)
                }
            }
            b's' => self.save_cursor(),    // SCOSC
            b'u' => self.restore_cursor(), // SCORC
            _ => {}                        // t (window ops) and the rest
        }
    }

    /// DECSTR: modes and pen to their defaults, the text left alone.
    fn soft_reset(&mut self) {
        self.pen = CellAttributes::default();
        (self.insert_mode, self.origin_mode, self.autowrap, self.cursor_visible) = (false, false, true, true);
        (self.application_cursor_keys, self.application_keypad) = (false, false);
        (self.scroll_top, self.scroll_bottom) = (0, self.rows - 1);
        (self.g0_graphics, self.g1_graphics, self.shifted) = (false, false, false);
        (self.saved, self.saved_alternate) = (Saved::initial(), Saved::initial());
        self.pending_wrap = false
    }

    fn set_private_mode(&mut self, m: i64, on: bool) {
        match m {
            1 => self.application_cursor_keys = on,
            6 => {
                self.origin_mode = on;
                self.cursor_position(1, 1, false)
            }
            7 => {
                self.autowrap = on;
                if !on {
                    self.pending_wrap = false
                }
            }
            25 => self.cursor_visible = on,
            47 | 1047 => {
                if on != self.using_alternate {
                    if on {
                        self.alternate = blank(self.rows, self.cols)
                    }
                    self.using_alternate = on
                }
            }
            1048 => {
                if on {
                    self.save_cursor()
                } else {
                    self.restore_cursor()
                }
            }
            // Save the cursor on the main screen, switch, clear; and back.
            1049 => {
                if on && !self.using_alternate {
                    self.save_cursor();
                    self.using_alternate = true;
                    self.alternate = blank(self.rows, self.cols);
                    self.saved_alternate = self.saved
                } else if !on && self.using_alternate {
                    self.using_alternate = false;
                    self.restore_cursor()
                }
            }
            2004 => self.bracketed_paste = on,
            _ => {} // 3, 5, 12, mouse modes: ignored
        }
    }

    fn reply(&mut self, s: &str) {
        self.responses.extend_from_slice(s.as_bytes())
    }

    // MARK: cursor movement

    fn move_to(&mut self, r: i64, c: i64) {
        self.cursor_row = r.clamp(0, self.rows as i64 - 1) as usize;
        self.cursor_col = c.clamp(0, self.cols as i64 - 1) as usize;
        self.pending_wrap = false
    }

    /// CUU and CUD stop at the scroll region's edge when they start inside it.
    fn move_up(&mut self, n: usize) {
        let limit = if self.cursor_row >= self.scroll_top { self.scroll_top } else { 0 };
        let r = (self.cursor_row as i64 - n as i64).max(limit as i64);
        self.move_to(r, self.cursor_col as i64)
    }

    fn move_down(&mut self, n: usize) {
        let limit = if self.cursor_row <= self.scroll_bottom { self.scroll_bottom } else { self.rows - 1 };
        self.move_to((self.cursor_row + n).min(limit) as i64, self.cursor_col as i64)
    }

    /// CUP, 1-based; relative to the scroll region in origin mode.
    fn cursor_position(&mut self, row: usize, col: usize, absolute_row: bool) {
        let r = if self.origin_mode && !absolute_row { (self.scroll_top + row - 1).min(self.scroll_bottom) } else { row - 1 };
        self.move_to(r as i64, col as i64 - 1)
    }

    // MARK: erasing and editing

    /// Erased cells take the pen's background, nothing else (`bce`).
    fn blank_cell(&self) -> Cell {
        Cell::new(' ', CellAttributes { bg: self.pen.bg, ..CellAttributes::default() })
    }
    fn blank_line(&self) -> Vec<Cell> {
        vec![self.blank_cell(); self.cols]
    }

    fn erase_display(&mut self, mode: usize) {
        self.pending_wrap = false;
        let (line, row) = (self.blank_line(), self.cursor_row);
        match mode {
            0 => {
                self.erase_line(0);
                self.grid_mut()[row + 1..].fill(line)
            }
            1 => {
                self.erase_line(1);
                self.grid_mut()[..row].fill(line)
            }
            2 => self.grid_mut().fill(line),
            3 => self.scrollback.clear(),
            _ => {}
        }
    }

    fn erase_line(&mut self, mode: usize) {
        self.pending_wrap = false;
        let (b, c) = (self.blank_cell(), self.cursor_col);
        let line = self.line_mut();
        match mode {
            0 => line[c..].fill(b),
            1 => line[..=c].fill(b),
            2 => line.fill(b),
            _ => {}
        }
    }

    fn erase_cells(&mut self, n: usize) {
        self.pending_wrap = false;
        let (b, c) = (self.blank_cell(), self.cursor_col);
        let end = self.cols.min(c + n);
        self.line_mut()[c..end].fill(b)
    }

    fn insert_cells(&mut self, n: usize) {
        self.pending_wrap = false;
        let (b, c) = (self.blank_cell(), self.cursor_col);
        let n = n.min(self.cols - c);
        let line = self.line_mut();
        line.splice(c..c, std::iter::repeat_n(b, n));
        line.truncate(line.len() - n)
    }

    fn delete_cells(&mut self, n: usize) {
        self.pending_wrap = false;
        let (b, c) = (self.blank_cell(), self.cursor_col);
        let n = n.min(self.cols - c);
        let line = self.line_mut();
        line.drain(c..c + n);
        line.extend(std::iter::repeat_n(b, n))
    }

    /// IL and DL work from the cursor's line to the region's bottom, and
    /// only inside the region.
    fn insert_lines(&mut self, n: usize) {
        if self.cursor_row < self.scroll_top || self.cursor_row > self.scroll_bottom {
            return;
        }
        let top = std::mem::replace(&mut self.scroll_top, self.cursor_row);
        self.scroll_down(n);
        self.scroll_top = top;
        self.cursor_col = 0
    }

    fn delete_lines(&mut self, n: usize) {
        if self.cursor_row < self.scroll_top || self.cursor_row > self.scroll_bottom {
            return;
        }
        let top = std::mem::replace(&mut self.scroll_top, self.cursor_row);
        self.scroll_up(n, false);
        self.scroll_top = top;
        self.cursor_col = 0
    }

    // MARK: SGR

    fn sgr(&mut self, p: &[i64]) {
        let p: &[i64] = if p.is_empty() { &[0] } else { p };
        let pen = &mut self.pen;
        let mut i = 0;
        while i < p.len() {
            let v = p[i];
            match v {
                0 => *pen = CellAttributes::default(),
                1 => pen.bold = true,
                2 => pen.dim = true,
                3 => pen.italic = true,
                4 => pen.underline = true,
                5 | 6 => pen.blink = true,
                7 => pen.inverse = true,
                8 => pen.invisible = true,
                9 => pen.strike = true,
                21 | 22 => (pen.bold, pen.dim) = (false, false),
                23 => pen.italic = false,
                24 => pen.underline = false,
                25 => pen.blink = false,
                27 => pen.inverse = false,
                28 => pen.invisible = false,
                29 => pen.strike = false,
                30..=37 => pen.fg = TermColor::Indexed((v - 30) as u8),
                39 => pen.fg = TermColor::Default,
                40..=47 => pen.bg = TermColor::Indexed((v - 40) as u8),
                49 => pen.bg = TermColor::Default,
                90..=97 => pen.fg = TermColor::Indexed((v - 90 + 8) as u8),
                100..=107 => pen.bg = TermColor::Indexed((v - 100 + 8) as u8),
                // 38;5;n and 38;2;r;g;b, and the same after 48.
                38 | 48 => {
                    let byte = |x: i64| x.clamp(0, 255) as u8;
                    let color = if i + 2 < p.len() && p[i + 1] == 5 {
                        i += 2;
                        Some(TermColor::Indexed(byte(p[i])))
                    } else if i + 4 < p.len() && p[i + 1] == 2 {
                        i += 4;
                        Some(TermColor::Rgb(byte(p[i - 2]), byte(p[i - 1]), byte(p[i])))
                    } else {
                        i = p.len(); // malformed: the rest is not trustworthy
                        None
                    };
                    match (color, v) {
                        (Some(c), 38) => pen.fg = c,
                        (Some(c), _) => pen.bg = c,
                        (None, _) => {}
                    }
                }
                _ => {}
            }
            i += 1
        }
    }

    // MARK: storage

    fn reset_tabs(&mut self) {
        self.tab_stops = (8..self.cols).step_by(8).collect()
    }

    fn grid_mut(&mut self) -> &mut Vec<Vec<Cell>> {
        if self.using_alternate { &mut self.alternate } else { &mut self.main }
    }

    fn line_mut(&mut self) -> &mut Vec<Cell> {
        let r = self.cursor_row;
        &mut self.grid_mut()[r]
    }
}

/// DEC special graphics: what `ESC ( 0` makes of `` ` ``–`~`, the line
/// drawing ncurses' ACS, mc and tmux use.
fn dec_graphics(c: char) -> Option<char> {
    const FROM: &str = "`abcdefghijklmnopqrstuvwxyz{|}~";
    const TO: &str = "◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·";
    FROM.chars().position(|f| f == c).and_then(|i| TO.chars().nth(i))
}
