//! Scenes (Scene.swift): what a window draws, and one frame of it rendered
//! offscreen, for headless checks and the goldens.

use aquadraw::canvas::Canvas;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::{Rect, Runner};
use aquadraw::text::Style;
use aquadraw::theme::Theme;
use abyss_sys::{self as ffi, Context, Pattern, Surface};

/// What AquaDemo shows (AQUA_SCENE).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SceneKind {
    Window,
    Widgets,
    Scroll,
    Tabs,
    Sheet,
}

impl SceneKind {
    /// The scene AQUA_SCENE names, its title and its size, as AquaDemo has
    /// them. None for one not ported yet.
    pub fn named(name: Option<&str>) -> Option<(SceneKind, &'static str, i32, i32)> {
        match name {
            Some("widgets") => Some((SceneKind::Widgets, "Aqua Controls", 460, 360)),
            Some("scroll") => Some((SceneKind::Scroll, "Scroll", 360, 420)),
            Some("tabs") => Some((SceneKind::Tabs, "Tab View", 480, 380)),
            Some("sheet") => Some((SceneKind::Sheet, "Sheets", 440, 320)),
            None | Some("window") => Some((SceneKind::Window, "AbyssBSD", 440, 300)),
            _ => None,
        }
    }
}

/// The demo window: chrome, a welcome, a click counter, a live text field
/// and a default button. Returns the button's rect, for hit-testing.
#[allow(clippy::too_many_arguments)]
pub fn paint_aqua_window(c: &mut Canvas, w: f64, h: f64, title: &str, clicks: u64, pressed: bool, typed: &str, focused: bool) -> Rect {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, title, false, true);
    let t = c.theme.tokens.clone();
    c.text_left("Welcome to AbyssBSD", 24.0, 70.0, t.body_text, 16.0, Style::Regular, Role::Interface);
    c.text_left("A Swift 6 desktop, dressed in Aqua.", 24.0, 94.0, t.body_text.with_a(0.7), t.font_size, Style::Regular, Role::Interface);
    c.text_left(&format!("Clicks: {clicks}"), 24.0, 132.0, t.body_text, t.font_size, Style::Regular, Role::Interface);
    // A live text field: real keyboard input lands here.
    c.text_field(Rect::new(24.0, 150.0, w - 48.0, 26.0), typed, focused, "");
    let (bw, bh) = (120.0, 30.0);
    let button = Rect::new(w - bw - 20.0, h - bh - 20.0, bw, bh);
    c.gel_button(button, "Click Me", true, pressed);
    button
}

/// One scene rendered to a PNG: the desktop-grey backdrop, and the scene's
/// window inset on it.
#[allow(clippy::too_many_arguments)]
pub fn render_scene_png(path: &str, kind: SceneKind, width: i32, height: i32, scale: i32, title: &str, clicks: u64, runner: &mut Runner, theme: &Theme) -> bool {
    let cs = Surface::image(ffi::FORMAT_ARGB32, width * scale, height * scale);
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        let was = runner.text.render_scale;
        runner.text.render_scale = scale; // shape and hint on the device grid
        let g = Pattern::linear(0.0, 0.0, 0.0, height as f64);
        g.add_color_stop_rgba(0.0, 0.62, 0.66, 0.72, 1.0);
        g.add_color_stop_rgba(1.0, 0.50, 0.54, 0.60, 1.0);
        cr.set_source(&g);
        cr.paint();
        let inset = 16.0;
        cr.save();
        cr.translate(inset, inset);
        let (cw, ch) = (width as f64 - 2.0 * inset, height as f64 - 2.0 * inset);
        let mut c = Canvas::new(&cr, runner, theme);
        match kind {
            SceneKind::Window => {
                paint_aqua_window(&mut c, cw, ch, title, clicks, false, "", false);
            }
            SceneKind::Scroll => {
                crate::scroll::paint_scroll(&mut c, cw, ch, 0.0);
            }
            SceneKind::Tabs => {
                crate::tabs::paint_tabs(&mut c, cw, ch, crate::tabs::TabsState::default());
            }
            // The sheet fully out, for the still.
            SceneKind::Sheet => {
                crate::sheet::paint_sheet_scene(&mut c, cw, ch, 1.0, true, "—");
            }
            SceneKind::Widgets => {
                crate::widgets::paint_widgets(&mut c, cw, ch, &crate::widgets::WidgetState::default(), Some(crate::widgets::WidgetFocus::Ok));
            }
        }
        cr.restore();
        runner.text.render_scale = was;
    }
    cs.flush();
    cs.write_png(path)
}

/// An open menu (Scene.swift's renderMenuPNG): the Finder's File menu with
/// New Folder hovered, or, with `marks`, the parts File never shows: a
/// checked row, and a submenu's ▸ plain, disabled and highlighted.
pub fn render_menu_png(path: &str, scale: i32, marks: bool, runner: &mut Runner, theme: &Theme) -> bool {
    use crate::commands::{aqua_menu_items, aqua_menu_rows, AquaMenuItem};
    use crate::finder_commands::{finder_menu_bar, static_enablement};
    use crate::menu::AquaMenu;
    let t = theme.tokens.clone();
    let rows = if marks {
        vec![AquaMenuItem::new("as Icons"), AquaMenuItem::new("as List"), AquaMenuItem::separator(), AquaMenuItem::new("Arrange By").submenu(), AquaMenuItem::new("Label").disabled().submenu(), AquaMenuItem::new("Show View Options").key("⌘J").submenu()]
    } else {
        let bar = finder_menu_bar();
        let Some(file) = bar.menus.iter().find(|m| m.title == "File") else { return false };
        aqua_menu_items(file, &static_enablement)
    };
    let hover = if marks { rows.len() - 1 } else { 1 };
    let mut menu = AquaMenu::new(rows, if marks { Some(0) } else { None });
    let was = runner.text.render_scale;
    runner.text.render_scale = scale;
    let w = menu.preferred_width(runner, &t).max(150.0) as i32;
    let h = menu.preferred_height(&t).ceil() as i32;
    let (ry, rh) = aqua_menu_rows(&menu.items, &t)[hover];
    menu.pointer_moved(ry + rh / 2.0, &t);
    let cs = Surface::image(ffi::FORMAT_ARGB32, w * scale, h * scale);
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        // A transparent ground, so the rounded corners read.
        cr.set_operator(0); // CLEAR
        cr.paint();
        cr.set_operator(ffi::OPERATOR_OVER);
        let mut c = Canvas::new(&cr, runner, theme);
        menu.render(&mut c, w as f64, h as f64);
    }
    runner.text.render_scale = was;
    cs.flush();
    cs.write_png(path)
}

/// Every icon in the theme, or in a list file, at 16, 32 and 64 points
/// (Scene.swift's renderIconSheetPNG): `icon.*` and `dock.icon.*`, sorted,
/// twenty to a column.
pub fn render_icon_sheet_png(path: &str, list_file: Option<&str>, scale: i32, runner: &mut Runner, theme: &Theme) -> bool {
    use aquadraw::drawlist::{DrawListFile, DrawState};
    use aquadraw::runner::DrawContext;
    let own;
    let lists = match list_file {
        None => &theme.lists,
        Some(f) => {
            let Ok(text) = std::fs::read_to_string(f) else { return false };
            match DrawListFile::parse(&text) {
                Ok(l) => {
                    own = l;
                    &own
                }
                Err(e) => {
                    eprintln!("AquaDemo: {f}: {e}");
                    return false;
                }
            }
        }
    };
    let mut names: Vec<&String> = lists.lists.keys().filter(|k| (k.starts_with("icon.") || k.starts_with("dock.icon.")) && !k.ends_with(".small")).collect();
    names.sort();
    if names.is_empty() {
        return false;
    }
    let per_column = 20;
    let columns = names.len().div_ceil(per_column);
    let (row_h, col_w) = (72.0, 140.0);
    let (w, h) = ((col_w * columns as f64) as i32 + 8, (row_h * names.len().min(per_column) as f64) as i32 + 8);
    let cs = Surface::image(ffi::FORMAT_ARGB32, w * scale, h * scale);
    let was = runner.text.render_scale;
    runner.text.render_scale = scale;
    {
        let cr = Context::new(&cs);
        cr.scale(scale as f64, scale as f64);
        let bg = theme.tokens.content_background;
        cr.set_source_rgba(bg.r, bg.g, bg.b, bg.a);
        cr.paint();
        let small_below = theme.tokens.icon_small_below;
        for (i, n) in names.iter().enumerate() {
            let (x0, y0) = (4.0 + col_w * (i / per_column) as f64, 4.0 + row_h * (i % per_column) as f64);
            let mut x = x0;
            for size in [16.0, 32.0, 64.0] {
                let r = Rect::new(x, y0 + (64.0 - size) / 2.0, size, size);
                if list_file.is_none() {
                    Canvas::new(&cr, runner, theme).icon(n, r);
                } else {
                    let small = format!("{n}.small");
                    let name = if r.w < small_below && lists.get(&small).is_some() { small.as_str() } else { n.as_str() };
                    if let Some(l) = lists.get(name) {
                        cr.new_path();
                        runner.run(l, &cr, &DrawContext::new(r, DrawState::NORMAL, ""));
                    }
                }
                x += size + 6.0;
            }
        }
    }
    runner.text.render_scale = was;
    cs.flush();
    cs.write_png(path)
}

/// R0's draw-list sheet, from `list_file`, with the loaded theme's roles.
pub fn render_drawlist_png(path: &str, list_file: &str, scale: i32, runner: &mut Runner) -> bool {
    let Ok(text) = std::fs::read_to_string(list_file) else { return false };
    let file = match aquadraw::drawlist::DrawListFile::parse(&text) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("AquaDemo: {list_file}: {e}");
            return false;
        }
    };
    let was = runner.text.render_scale;
    runner.text.render_scale = scale;
    let cs = Surface::image(ffi::FORMAT_ARGB32, aquadraw::scene::WIDTH * scale, aquadraw::scene::HEIGHT * scale);
    {
        let cr = Context::new(&cs);
        aquadraw::scene::drawlist(&cr, scale, &file, runner);
    }
    runner.text.render_scale = was;
    cs.flush();
    cs.write_png(path)
}
