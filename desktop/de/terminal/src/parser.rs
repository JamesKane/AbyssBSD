//! Bytes from a program into terminal actions (VTParser.swift, P15.4a).
//!
//! The state machine Paul Williams drew for DEC's VT500 series
//! (vt100.net/emu/dec_ansi_parser), cut to an xterm subset: ground, escape,
//! CSI, OSC, and a DCS recognised and ignored. It knows nothing of screens.
//!
//! UTF-8 is decoded in ground only, as xterm does: a control byte inside a
//! rune aborts it (U+FFFD) and is then acted on, so a stray ESC is never
//! swallowed by a broken rune.

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VtAction {
    /// A character to put on the screen.
    Print(char),
    /// A C0 control: BEL, BS, HT, LF, VT, FF, CR, SO, SI.
    Execute(u8),
    /// `CSI params intermediates final`: `ESC [ ? 1 0 4 9 h`.
    Csi { params: Vec<i64>, intermediates: Vec<u8>, private: Option<u8>, final_byte: u8 },
    /// `ESC intermediates final`: `ESC 7`, `ESC ( 0`.
    Esc { intermediates: Vec<u8>, final_byte: u8 },
    /// `OSC string (BEL|ST)`: `ESC ] 0 ; title BEL`.
    Osc(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
enum State {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    CsiEntry,
    CsiParam,
    CsiIntermediate,
    CsiIgnore,
    Osc,
    Dcs,
}

/// Longest parameter list and OSC string kept: a terminal must not grow
/// without bound for a broken or hostile program.
const MAX_PARAMS: usize = 32;
const MAX_OSC: usize = 4096;

#[derive(Clone, Debug, Default)]
pub struct VtParser {
    state: State,
    params: Vec<i64>,
    current: Option<i64>,
    intermediates: Vec<u8>,
    private: Option<u8>,
    osc: Vec<u8>,
    /// An ESC inside OSC/DCS: a `\` next ends the string.
    esc_in_string: bool,
    utf8_need: u32,
    utf8_value: u32,
}

impl VtParser {
    pub fn new() -> VtParser {
        VtParser::default()
    }

    pub fn feed(&mut self, bytes: &[u8], emit: &mut impl FnMut(VtAction)) {
        for &b in bytes {
            self.step(b, emit)
        }
    }

    fn broken_rune(&mut self, emit: &mut impl FnMut(VtAction)) {
        if self.utf8_need > 0 {
            emit(VtAction::Print('\u{FFFD}'));
            self.utf8_need = 0
        }
    }

    pub fn step(&mut self, b: u8, emit: &mut impl FnMut(VtAction)) {
        use State::*;
        // Anywhere: CAN and SUB abort a sequence; ESC starts one (but in a
        // string it may be the start of ST).
        match b {
            0x18 | 0x1A => {
                self.broken_rune(emit);
                self.state = Ground;
                return;
            }
            0x1B if self.state != Osc && self.state != Dcs => {
                self.broken_rune(emit);
                return self.enter_escape();
            }
            _ => {}
        }
        match self.state {
            Ground => self.ground(b, emit),
            Escape => match b {
                ..0x20 => emit(VtAction::Execute(b)),
                0x20..=0x2F => {
                    self.intermediates.push(b);
                    self.state = EscapeIntermediate
                }
                0x5B => self.enter_csi(),
                0x5D => {
                    self.osc.clear();
                    self.esc_in_string = false;
                    self.state = Osc
                }
                // DCS, and SOS PM APC: ignored alike.
                0x50 | 0x58 | 0x5E | 0x5F => {
                    self.esc_in_string = false;
                    self.state = Dcs
                }
                0x30..=0x7E => {
                    emit(VtAction::Esc { intermediates: std::mem::take(&mut self.intermediates), final_byte: b });
                    self.state = Ground
                }
                _ => {}
            },
            EscapeIntermediate => match b {
                ..0x20 => emit(VtAction::Execute(b)),
                0x20..=0x2F => {
                    if self.intermediates.len() < 4 {
                        self.intermediates.push(b)
                    }
                }
                0x30..=0x7E => {
                    emit(VtAction::Esc { intermediates: std::mem::take(&mut self.intermediates), final_byte: b });
                    self.state = Ground
                }
                _ => {}
            },
            CsiEntry | CsiParam => match b {
                ..0x20 => emit(VtAction::Execute(b)),
                b'0'..=b'9' => {
                    let v = self.current.unwrap_or(0).saturating_mul(10).saturating_add(i64::from(b - b'0'));
                    self.current = Some(v.min(65535));
                    self.state = CsiParam
                }
                // `;`, and `:` as xterm's SGR sub-separator.
                b';' | b':' => {
                    self.push_param();
                    self.state = CsiParam
                }
                // `< = > ?`: a private marker, first or not at all.
                0x3C..=0x3F => {
                    if self.state == CsiEntry {
                        self.private = Some(b);
                        self.state = CsiParam
                    } else {
                        self.state = CsiIgnore
                    }
                }
                0x20..=0x2F => {
                    self.intermediates.push(b);
                    self.state = CsiIntermediate
                }
                0x40..=0x7E => self.dispatch_csi(b, emit),
                _ => {}
            },
            CsiIntermediate => match b {
                ..0x20 => emit(VtAction::Execute(b)),
                0x20..=0x2F => {
                    if self.intermediates.len() < 4 {
                        self.intermediates.push(b)
                    }
                }
                0x30..=0x3F => self.state = CsiIgnore,
                0x40..=0x7E => self.dispatch_csi(b, emit),
                _ => {}
            },
            CsiIgnore => match b {
                ..0x20 => emit(VtAction::Execute(b)),
                0x40..=0x7E => self.state = Ground,
                _ => {}
            },
            Osc => {
                // BEL ends it (xterm), as ST does.
                if b == 0x07 {
                    return self.finish_osc(emit);
                }
                if self.esc_in_string {
                    self.esc_in_string = false;
                    if b == b'\\' {
                        return self.finish_osc(emit);
                    }
                    // An ESC that is not ST aborts the string and starts a sequence.
                    self.enter_escape();
                    return self.step(b, emit);
                }
                if b == 0x1B {
                    self.esc_in_string = true
                } else if b >= 0x20 && self.osc.len() < MAX_OSC {
                    self.osc.push(b)
                }
            }
            Dcs => {
                if self.esc_in_string {
                    self.esc_in_string = false;
                    if b == b'\\' {
                        self.state = Ground;
                        return;
                    }
                    self.enter_escape();
                    return self.step(b, emit);
                }
                if b == 0x1B {
                    self.esc_in_string = true
                }
            }
        }
    }

    fn ground(&mut self, b: u8, emit: &mut impl FnMut(VtAction)) {
        if self.utf8_need > 0 {
            if b & 0xC0 == 0x80 {
                self.utf8_value = (self.utf8_value << 6) | u32::from(b & 0x3F);
                self.utf8_need -= 1;
                if self.utf8_need == 0 {
                    emit(VtAction::Print(char::from_u32(self.utf8_value).unwrap_or('\u{FFFD}')))
                }
                return;
            }
            // A broken rune: say so, then take this byte on its own.
            self.broken_rune(emit)
        }
        match b {
            ..0x20 => emit(VtAction::Execute(b)),
            0x7F => {} // DEL: ignored
            0x20..0x7F => emit(VtAction::Print(char::from(b))),
            0xC2..=0xDF => (self.utf8_need, self.utf8_value) = (1, u32::from(b & 0x1F)),
            0xE0..=0xEF => (self.utf8_need, self.utf8_value) = (2, u32::from(b & 0x0F)),
            0xF0..=0xF4 => (self.utf8_need, self.utf8_value) = (3, u32::from(b & 0x07)),
            // A lone continuation, or not UTF-8.
            _ => emit(VtAction::Print('\u{FFFD}')),
        }
    }

    fn enter_escape(&mut self) {
        self.intermediates.clear();
        self.state = State::Escape
    }

    fn enter_csi(&mut self) {
        self.params.clear();
        self.current = None;
        self.intermediates.clear();
        self.private = None;
        self.state = State::CsiEntry
    }

    fn push_param(&mut self) {
        if self.params.len() < MAX_PARAMS {
            self.params.push(self.current.unwrap_or(0))
        }
        self.current = None
    }

    fn dispatch_csi(&mut self, final_byte: u8, emit: &mut impl FnMut(VtAction)) {
        if self.current.is_some() || !self.params.is_empty() {
            self.push_param()
        }
        emit(VtAction::Csi { params: std::mem::take(&mut self.params), intermediates: std::mem::take(&mut self.intermediates), private: self.private, final_byte });
        self.state = State::Ground
    }

    fn finish_osc(&mut self, emit: &mut impl FnMut(VtAction)) {
        emit(VtAction::Osc(String::from_utf8_lossy(&std::mem::take(&mut self.osc)).into_owned()));
        self.state = State::Ground
    }
}
