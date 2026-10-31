//! A Jaguar window you can use (AquaWindow.swift): a scene drawn on a
//! surface Window, and the clicks, drags and keys each scene answers. The
//! chrome is the compositor's to act on: a press on it is one request.

use crate::scene::{paint_aqua_window, SceneKind};
use crate::live_menu::LiveMenu;
use crate::menu::AquaMenu;
use crate::toolkit::Toolkit;
use crate::{scroll, sheet, tabs, widgets};
use aquadraw::canvas::SLIDER_THUMB_RADIUS;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit, Gadget};
use aquadraw::runner::Rect;
use std::cell::RefCell;
use std::rc::{Rc, Weak};
use surface::{Display, KeyEvent, KeySym, PopupDelegate, RenderTarget, ResizeEdge, Window, WindowDelegate};
use widgets::{WidgetFocus, WidgetLayout, WidgetState, FOCUS_ORDER};

const BTN_LEFT: u32 = 0x110;

#[derive(Default)]
struct State {
    pointer: (f64, f64),
    // The window scene.
    clicks: u64,
    button: Rect,
    button_pressed: bool,
    typed: String,
    // Widgets.
    widgets: WidgetState,
    widget_layout: WidgetLayout,
    dragging_slider: bool,
    /// Keyboard focus starts on the default button, as Aqua's does.
    focus: Option<WidgetFocus>,
    /// The Appearance pop-up's menu, while it is open; and a press that
    /// asked for it, opened once the state is let go.
    menu: Option<Rc<LiveMenu>>,
    open_menu: bool,
    // Scroll.
    offset: f64,
    scroll_layout: scroll::ScrollLayout,
    dragging_thumb: bool,
    thumb_grab_dy: f64,
    // Tabs.
    tabs: tabs::TabsState,
    tabs_layout: tabs::TabsLayout,
    // The sheet: progress 0…1 drives its slide.
    sheet_visible: bool,
    sheet_progress: f64,
    sheet_opening: bool,
    sheet_action: String,
    sheet: sheet::SheetScene,
}

pub struct AquaWindow {
    me: Weak<AquaWindow>,
    window: RefCell<Option<Rc<Window>>>,
    toolkit: Rc<Toolkit>,
    title: String,
    kind: SceneKind,
    state: RefCell<State>,
}

impl AquaWindow {
    /// AQUA_SCALE pins the buffer scale (HiDPI without a HiDPI output);
    /// otherwise the window follows its outputs.
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>, title: &str, kind: SceneKind, width: i32, height: i32) -> Option<Rc<AquaWindow>> {
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let me = Rc::new_cyclic(|me| AquaWindow {
            me: me.clone(),
            window: RefCell::new(None),
            toolkit: toolkit.clone(),
            title: title.into(),
            kind,
            state: RefCell::new(State { focus: Some(WidgetFocus::Ok), sheet_action: "—".into(), ..State::default() }),
        });
        let delegate: Weak<dyn WindowDelegate> = Rc::downgrade(&(me.clone() as Rc<dyn WindowDelegate>));
        let w = Window::new(display, title, "org.abyssbsd.aquademo", width, height, pinned.unwrap_or(1), pinned.is_none(), delegate)?;
        *me.window.borrow_mut() = Some(w);
        Some(me)
    }

    /// Draw again, for a caller driving the window from outside.
    pub fn refresh(&self) {
        let w = self.window.borrow().clone();
        if let Some(w) = w {
            w.set_needs_display()
        }
    }

    /// A press on the chrome, acted on; false when it was not one.
    /// **A client cannot move, resize or zoom its own window**: it asks.
    fn chrome_press(&self, w: &Window) -> bool {
        let (x, y) = self.state.borrow().pointer;
        chrome_press(&self.toolkit, w, x, y)
    }

    fn slider_value(s: &State, x: f64) -> f64 {
        let t = s.widget_layout.slider_track;
        let usable = t.w - 2.0 * SLIDER_THUMB_RADIUS;
        if usable <= 0.0 { 0.0 } else { ((x - t.x - SLIDER_THUMB_RADIUS) / usable).clamp(0.0, 1.0) }
    }

    fn scroll_by(s: &mut State, dy: f64) -> bool {
        let old = s.offset;
        s.offset = (s.offset + dy).clamp(0.0, scroll::max_offset(s.scroll_layout.list.h));
        s.offset != old
    }

    fn thumb(s: &State) -> Option<Rect> {
        let l = &s.scroll_layout;
        scroll::thumb_rect(l.track, s.offset, l.list.h, scroll::content_height())
    }

    /// The offset that puts the thumb's top at `top`.
    fn scroll_to_thumb_top(s: &mut State, top: f64) {
        let Some(thumb) = AquaWindow::thumb(s) else { return };
        let travel = s.scroll_layout.track.h - thumb.h;
        if travel > 0.0 {
            let t = ((top - s.scroll_layout.track.y) / travel).clamp(0.0, 1.0);
            s.offset = t * scroll::max_offset(s.scroll_layout.list.h);
        }
    }

    /// Open the Appearance pop-up's menu below the button, if a press or a
    /// key asked; a choice sets the value.
    fn open_menu_if_asked(&self, w: &Window) {
        let (r, selected) = {
            let mut s = self.state.borrow_mut();
            if !std::mem::take(&mut s.open_menu) || s.menu.as_ref().is_some_and(|m| m.is_open()) {
                return;
            }
            (s.widget_layout.popup, s.widgets.popup)
        };
        let m = LiveMenu::new(&self.toolkit, AquaMenu::of_titles(&widgets::POPUP_OPTIONS, selected));
        let (_, h) = m.preferred_size(r.w);
        let anchor = (r.x.round() as i32, r.y.round() as i32, r.w.round() as i32, r.h.round() as i32);
        let Some(p) = w.open_popup(anchor, r.w.round() as i32, h, Rc::downgrade(&m) as Weak<dyn PopupDelegate>) else { return };
        m.set_popup(p);
        let me = self.me.clone();
        m.on_choose(move |i| {
            let Some(aw) = me.upgrade() else { return };
            let m = {
                let mut s = aw.state.borrow_mut();
                s.widgets.popup = i;
                s.menu.take()
            };
            if let Some(m) = m {
                m.close_all()
            }
            aw.refresh()
        });
        let me = self.me.clone();
        m.on_dismiss(move || {
            if let Some(aw) = me.upgrade() {
                aw.state.borrow_mut().menu = None
            }
        });
        self.state.borrow_mut().menu = Some(m);
    }

    /// A press or release in the scene, past the chrome: whether to redraw.
    fn scene_button(&self, pressed: bool) -> bool {
        let mut s = self.state.borrow_mut();
        let (x, y) = s.pointer;
        match self.kind {
            SceneKind::Wallpaper | SceneKind::MenuBar | SceneKind::Dock | SceneKind::Finder | SceneKind::Prefs | SceneKind::Installer | SceneKind::Terminal => false,
            SceneKind::Window => {
                if pressed {
                    s.button_pressed = s.button.contains(x, y);
                    s.button_pressed
                } else if s.button_pressed {
                    if s.button.contains(x, y) {
                        s.clicks += 1
                    }
                    s.button_pressed = false;
                    true
                } else {
                    false
                }
            }
            SceneKind::Widgets => {
                if !pressed {
                    s.dragging_slider = false;
                    let held = s.widgets.ok_pressed || s.widgets.cancel_pressed;
                    s.widgets.ok_pressed = false;
                    s.widgets.cancel_pressed = false;
                    return held;
                }
                let l = &s.widget_layout;
                if let Some(i) = l.checks.iter().position(|r| r.contains(x, y)) {
                    s.focus = Some(WidgetFocus::Check(i));
                    s.widgets.checks[i] = !s.widgets.checks[i];
                } else if let Some(i) = l.radios.iter().position(|r| r.contains(x, y)) {
                    s.focus = Some(WidgetFocus::Radio);
                    s.widgets.radio = i;
                } else if l.slider_track.contains(x, y) {
                    s.focus = Some(WidgetFocus::Slider);
                    s.dragging_slider = true;
                    s.widgets.slider = AquaWindow::slider_value(&s, x);
                } else if l.popup.contains(x, y) {
                    s.focus = Some(WidgetFocus::Popup);
                    s.open_menu = true;
                } else if l.cancel_button.contains(x, y) {
                    s.focus = Some(WidgetFocus::Cancel);
                    s.widgets.cancel_pressed = true;
                } else if l.ok_button.contains(x, y) {
                    s.focus = Some(WidgetFocus::Ok);
                    s.widgets.ok_pressed = true;
                } else {
                    return false;
                }
                true
            }
            SceneKind::Scroll => {
                if !pressed {
                    s.dragging_thumb = false;
                    return false;
                }
                let vp = s.scroll_layout.list.h;
                if let Some(thumb) = AquaWindow::thumb(&s)
                    && thumb.contains(x, y)
                {
                    s.dragging_thumb = true;
                    s.thumb_grab_dy = y - thumb.y;
                    return false;
                }
                if s.scroll_layout.up_arrow.contains(x, y) {
                    return AquaWindow::scroll_by(&mut s, -scroll::ROW_HEIGHT);
                }
                if s.scroll_layout.down_arrow.contains(x, y) {
                    return AquaWindow::scroll_by(&mut s, scroll::ROW_HEIGHT);
                }
                // A click in the track pages toward it.
                match AquaWindow::thumb(&s) {
                    Some(thumb) if s.scroll_layout.track.contains(x, y) => AquaWindow::scroll_by(&mut s, if y < thumb.y { -vp * 0.9 } else { vp * 0.9 }),
                    _ => false,
                }
            }
            SceneKind::Tabs => {
                if !pressed {
                    return false;
                }
                if let Some(i) = s.tabs_layout.segments.iter().position(|r| r.contains(x, y)) {
                    s.tabs.segment = i;
                    true
                } else if let Some(i) = s.tabs_layout.tabs.iter().position(|r| r.contains(x, y)) {
                    s.tabs.tab = i;
                    true
                } else {
                    false
                }
            }
            SceneKind::Sheet => {
                if !pressed {
                    return false;
                }
                if s.sheet_visible {
                    // Modal, and only once it is fully out.
                    if s.sheet_progress < 1.0 {
                        return false;
                    }
                    let action = if s.sheet.ok.contains(x, y) {
                        "Deleted"
                    } else if s.sheet.cancel.contains(x, y) {
                        "Cancelled"
                    } else {
                        return false;
                    };
                    s.sheet_action = action.into();
                    s.sheet_opening = false;
                    return true;
                }
                if s.sheet.base_button.contains(x, y) {
                    AquaWindow::open_sheet(&mut s);
                    return true;
                }
                false
            }
        }
    }

    fn open_sheet(s: &mut State) {
        s.sheet_visible = true;
        s.sheet_opening = true;
        s.sheet_progress = 0.0;
    }

    fn move_focus(s: &mut State, d: i64) {
        let n = FOCUS_ORDER.len() as i64;
        s.focus = Some(match s.focus.and_then(|f| FOCUS_ORDER.iter().position(|x| *x == f)) {
            Some(i) => FOCUS_ORDER[((i as i64 + d + n) % n) as usize],
            None => FOCUS_ORDER[0],
        });
    }

    /// A key in the scene: whether to redraw.
    fn scene_key(&self, e: &KeyEvent) -> bool {
        let mut s = self.state.borrow_mut();
        match self.kind {
            SceneKind::Wallpaper | SceneKind::MenuBar | SceneKind::Dock | SceneKind::Finder | SceneKind::Prefs | SceneKind::Installer | SceneKind::Terminal => false,
            SceneKind::Widgets => {
                if !e.pressed {
                    // Let go of the button the keyboard held.
                    let held = s.widgets.ok_pressed || s.widgets.cancel_pressed;
                    s.widgets.ok_pressed = false;
                    s.widgets.cancel_pressed = false;
                    return held;
                }
                let adjust = |s: &mut State, d: i64| match s.focus {
                    Some(WidgetFocus::Radio) => {
                        let n = widgets::RADIO_LABELS.len() as i64;
                        s.widgets.radio = ((s.widgets.radio as i64 + d + n) % n) as usize
                    }
                    Some(WidgetFocus::Slider) => s.widgets.slider = (s.widgets.slider + d as f64 * 0.05).clamp(0.0, 1.0),
                    _ => {}
                };
                match e.keysym {
                    KeySym::TAB => AquaWindow::move_focus(&mut s, 1),
                    KeySym::BACK_TAB => AquaWindow::move_focus(&mut s, -1),
                    // Return is the default button; Escape cancels.
                    KeySym::ENTER => s.widgets.ok_pressed = true,
                    KeySym::ESCAPE => s.widgets.cancel_pressed = true,
                    KeySym::SPACE => match s.focus {
                        Some(WidgetFocus::Check(i)) => s.widgets.checks[i] = !s.widgets.checks[i],
                        Some(WidgetFocus::Popup) => s.open_menu = true,
                        Some(WidgetFocus::Ok) => s.widgets.ok_pressed = true,
                        Some(WidgetFocus::Cancel) => s.widgets.cancel_pressed = true,
                        _ => {}
                    },
                    KeySym::LEFT | KeySym::DOWN => adjust(&mut s, -1),
                    KeySym::RIGHT | KeySym::UP => adjust(&mut s, 1),
                    _ => {}
                }
                true
            }
            SceneKind::Scroll => {
                if !e.pressed {
                    return false;
                }
                let vp = s.scroll_layout.list.h;
                match e.keysym {
                    KeySym::UP => AquaWindow::scroll_by(&mut s, -scroll::ROW_HEIGHT),
                    KeySym::DOWN => AquaWindow::scroll_by(&mut s, scroll::ROW_HEIGHT),
                    KeySym::PAGE_UP => AquaWindow::scroll_by(&mut s, -vp * 0.9),
                    KeySym::PAGE_DOWN => AquaWindow::scroll_by(&mut s, vp * 0.9),
                    KeySym::HOME => {
                        s.offset = 0.0;
                        true
                    }
                    KeySym::END => {
                        s.offset = scroll::max_offset(vp);
                        true
                    }
                    _ => false,
                }
            }
            SceneKind::Tabs => {
                let n = tabs::TAB_LABELS.len();
                match (e.pressed, e.keysym) {
                    (true, KeySym::LEFT) => s.tabs.tab = (s.tabs.tab + n - 1) % n,
                    (true, KeySym::RIGHT) => s.tabs.tab = (s.tabs.tab + 1) % n,
                    _ => return false,
                }
                true
            }
            SceneKind::Sheet => {
                if !e.pressed {
                    return false;
                }
                if !(s.sheet_visible && s.sheet_progress >= 1.0) {
                    if !s.sheet_visible && (e.keysym == KeySym::ENTER || e.keysym == KeySym::SPACE) {
                        AquaWindow::open_sheet(&mut s);
                        return true;
                    }
                    return false;
                }
                let action = match e.keysym {
                    KeySym::ENTER => "Deleted",
                    KeySym::ESCAPE => "Cancelled",
                    _ => return false,
                };
                s.sheet_action = action.into();
                s.sheet_opening = false;
                true
            }
            SceneKind::Window => {
                if !e.pressed {
                    return false;
                }
                match e.keysym {
                    KeySym::BACKSPACE => {
                        s.typed.pop();
                    }
                    KeySym::ESCAPE => s.typed.clear(),
                    KeySym::ENTER | KeySym::TAB => {}
                    // Any key that typed something lands in the field.
                    _ => s.typed.push_str(&e.text),
                }
                true
            }
        }
    }
}

/// A press at (x, y) on a window's chrome, acted on; false when it was not
/// on the chrome. **A client cannot move, resize or zoom its own window**:
/// it asks.
pub(crate) fn chrome_press(toolkit: &Toolkit, w: &Window, x: f64, y: f64) -> bool {
    let (sw, sh) = w.size();
    let t = toolkit.theme.borrow().tokens.clone();
    match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
        ChromeHit::Gadget(Gadget::Close) => {
            w.close();
            w.stop_display();
        }
        ChromeHit::Gadget(Gadget::Minimize) => {
            w.minimize();
        }
        ChromeHit::Gadget(Gadget::Depth) => {
            w.lower();
        }
        // The compositor's answer is what "zoomed" means: ask for the
        // opposite of what it last said.
        ChromeHit::Gadget(Gadget::Zoom) => w.set_maximized(!w.is_maximized()),
        ChromeHit::Title => w.begin_move(),
        ChromeHit::Resize(e) => w.begin_resize(match e {
            ChromeEdge::Bottom => ResizeEdge::BOTTOM,
            ChromeEdge::BottomLeft => ResizeEdge::BOTTOM_LEFT,
            ChromeEdge::BottomRight => ResizeEdge::BOTTOM_RIGHT,
        }),
        ChromeHit::Gadget(Gadget::Pill) | ChromeHit::Content => return false,
    }
    true
}

impl WindowDelegate for AquaWindow {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        self.toolkit.draw(target, |c, w, h| {
            let mut s = self.state.borrow_mut();
            match self.kind {
                SceneKind::Window => s.button = paint_aqua_window(c, w, h, &self.title, s.clicks, s.button_pressed, &s.typed.clone(), true),
                SceneKind::Widgets => {
                    let (state, focus) = (s.widgets.clone(), s.focus);
                    s.widget_layout = widgets::paint_widgets(c, w, h, &state, focus)
                }
                SceneKind::Scroll => s.scroll_layout = scroll::paint_scroll(c, w, h, s.offset),
                SceneKind::Tabs => s.tabs_layout = tabs::paint_tabs(c, w, h, s.tabs),
                SceneKind::Sheet => {
                    let action = s.sheet_action.clone();
                    s.sheet = sheet::paint_sheet_scene(c, w, h, s.sheet_progress, s.sheet_visible, &action)
                }
                SceneKind::Wallpaper | SceneKind::MenuBar | SceneKind::Dock | SceneKind::Finder | SceneKind::Prefs | SceneKind::Installer | SceneKind::Terminal => {}
            }
        })
    }

    /// The sheet's slide, a step a frame.
    fn did_render_frame(&self, w: &Window) {
        if self.kind != SceneKind::Sheet {
            return;
        }
        let step = 0.18;
        let again = {
            let mut s = self.state.borrow_mut();
            if s.sheet_opening {
                (s.sheet_progress < 1.0).then(|| s.sheet_progress = (s.sheet_progress + step).min(1.0)).is_some()
            } else if s.sheet_visible {
                if s.sheet_progress > 0.0 {
                    s.sheet_progress = (s.sheet_progress - step).max(0.0)
                } else {
                    s.sheet_visible = false
                }
                true
            } else {
                false
            }
        };
        if again {
            w.set_needs_display()
        }
    }

    fn pointer_moved(&self, w: &Window, x: f64, y: f64) {
        let redraw = {
            let mut s = self.state.borrow_mut();
            s.pointer = (x, y);
            if self.kind == SceneKind::Widgets && s.dragging_slider {
                s.widgets.slider = AquaWindow::slider_value(&s, x);
                true
            } else if self.kind == SceneKind::Scroll && s.dragging_thumb {
                let top = y - s.thumb_grab_dy;
                AquaWindow::scroll_to_thumb_top(&mut s, top);
                true
            } else {
                false
            }
        };
        if redraw {
            w.set_needs_display()
        }
    }

    /// The wheel scrolls the list, a notch a few rows.
    fn pointer_axis(&self, w: &Window, axis: u32, value: f64) {
        if self.kind == SceneKind::Scroll && axis == 0 && AquaWindow::scroll_by(&mut self.state.borrow_mut(), value * 2.0) {
            w.set_needs_display()
        }
    }

    fn pointer_button(&self, w: &Window, button: u32, pressed: bool) {
        if button != BTN_LEFT {
            return;
        }
        // The frame first, and only for a press.
        if pressed && self.chrome_press(w) {
            return;
        }
        if self.scene_button(pressed) {
            w.set_needs_display()
        }
        self.open_menu_if_asked(w)
    }

    /// What the compositor says the window now is (P9.4), said aloud:
    /// which window has focus is the whole effect of ⌘-Tab.
    fn state_changed(&self, w: &Window) {
        eprintln!("AquaWindow: {}{}", if w.is_activated() { "activated" } else { "deactivated" }, if w.is_maximized() { " maximized" } else { "" });
        w.set_needs_display()
    }

    /// **Say what arrived** (P9.5): a compositor that swallowed a key and
    /// one that never sent it draw the same picture.
    fn key_event(&self, w: &Window, e: &KeyEvent) {
        if e.pressed {
            eprintln!("AquaWindow: key {}{}", e.keysym, if e.text.is_empty() { String::new() } else { format!(" '{}'", e.text) });
        }
        // An open menu has the keys: a grabbing popup does not take the
        // keyboard from the window under it.
        let menu = self.state.borrow().menu.clone();
        if let Some(m) = menu.filter(|m| m.is_open()) {
            if e.pressed {
                m.key_down(e.keysym);
            }
            return;
        }
        if self.scene_key(e) {
            w.set_needs_display()
        }
        self.open_menu_if_asked(w)
    }
}
