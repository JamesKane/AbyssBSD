//! A Wayland client window: libwayland-client, the requests wl.c exports,
//! and `aw_create_shm` from de/cwayland. Enough for one xdg_toplevel with a
//! cairo-drawn shm buffer (RUST.md R0: a scene in a compositor), which is
//! what Surface.swift's first pass was too.

use crate::{cairo_surface_t, Surface, FORMAT_ARGB32};
use libc::{c_char, c_int, c_void};
use std::ffi::{CStr, CString};
use std::ptr;
use std::time::{Duration, Instant};

#[repr(C)]
pub struct wl_display {
    _p: [u8; 0],
}
#[repr(C)]
pub struct wl_proxy {
    _p: [u8; 0],
}
#[repr(C)]
pub struct wl_interface {
    _p: [u8; 0],
}

type P = *mut wl_proxy;

const WL_SHM_FORMAT_ARGB8888: u32 = 0;

unsafe extern "C" {
    fn wl_display_connect(name: *const c_char) -> *mut wl_display;
    fn wl_display_disconnect(d: *mut wl_display);
    fn wl_display_roundtrip(d: *mut wl_display) -> c_int;
    fn wl_display_dispatch(d: *mut wl_display) -> c_int;
    fn wl_display_flush(d: *mut wl_display) -> c_int;
    fn wl_display_get_fd(d: *mut wl_display) -> c_int;
    fn wl_proxy_add_listener(p: P, listener: *const c_void, data: *mut c_void) -> c_int;

    fn abw_display_get_registry(d: *mut wl_display) -> P;
    fn abw_registry_bind(r: P, name: u32, iface: *const wl_interface, version: u32) -> P;
    fn abw_compositor_create_surface(c: P) -> P;
    fn abw_shm_create_pool(shm: P, fd: i32, size: i32) -> P;
    fn abw_shm_pool_create_buffer(p: P, off: i32, w: i32, h: i32, stride: i32, fmt: u32) -> P;
    fn abw_shm_pool_destroy(p: P);
    fn abw_buffer_destroy(b: P);
    fn abw_surface_attach(s: P, b: P, x: i32, y: i32);
    fn abw_surface_damage_buffer(s: P, x: i32, y: i32, w: i32, h: i32);
    fn abw_surface_set_buffer_scale(s: P, scale: i32);
    fn abw_surface_commit(s: P);
    fn abw_surface_destroy(s: P);
    fn abw_xdg_wm_base_pong(b: P, serial: u32);
    fn abw_xdg_wm_base_get_xdg_surface(b: P, s: P) -> P;
    fn abw_xdg_surface_get_toplevel(s: P) -> P;
    fn abw_xdg_surface_ack_configure(s: P, serial: u32);
    fn abw_xdg_surface_destroy(s: P);
    fn abw_xdg_toplevel_set_title(t: P, title: *const c_char);
    fn abw_xdg_toplevel_set_app_id(t: P, id: *const c_char);
    fn abw_xdg_toplevel_destroy(t: P);
    static abw_compositor_iface: *const wl_interface;
    static abw_shm_iface: *const wl_interface;
    static abw_xdg_wm_base_iface: *const wl_interface;

    fn aw_create_shm(size: usize) -> c_int;

    fn cairo_image_surface_create_for_data(
        data: *mut u8,
        format: c_int,
        w: c_int,
        h: c_int,
        stride: c_int,
    ) -> *mut cairo_surface_t;
}

// MARK: listeners (event order as the protocol XML declares them)

#[repr(C)]
struct RegistryListener {
    global: unsafe extern "C" fn(*mut c_void, P, u32, *const c_char, u32),
    global_remove: unsafe extern "C" fn(*mut c_void, P, u32),
}
#[repr(C)]
struct WmBaseListener {
    ping: unsafe extern "C" fn(*mut c_void, P, u32),
}
#[repr(C)]
struct XdgSurfaceListener {
    configure: unsafe extern "C" fn(*mut c_void, P, u32),
}
/// xdg_toplevel version 1's events; bound at 1, so no others arrive.
#[repr(C)]
struct ToplevelListener {
    configure: unsafe extern "C" fn(*mut c_void, P, i32, i32, *mut c_void),
    close: unsafe extern "C" fn(*mut c_void, P),
}

/// What the listeners write, boxed so its address is stable.
#[derive(Default)]
struct State {
    compositor: Option<(u32, u32)>,
    shm: Option<(u32, u32)>,
    wm_base: Option<(u32, u32)>,
    configured: bool,
    closed: bool,
}

unsafe extern "C" fn on_global(data: *mut c_void, _r: P, name: u32, iface: *const c_char, version: u32) {
    let st = unsafe { &mut *(data as *mut State) };
    match unsafe { CStr::from_ptr(iface) }.to_bytes() {
        b"wl_compositor" => st.compositor = Some((name, version)),
        b"wl_shm" => st.shm = Some((name, version)),
        b"xdg_wm_base" => st.wm_base = Some((name, version)),
        _ => {}
    }
}
unsafe extern "C" fn on_global_remove(_d: *mut c_void, _r: P, _name: u32) {}
unsafe extern "C" fn on_ping(_d: *mut c_void, base: P, serial: u32) {
    unsafe { abw_xdg_wm_base_pong(base, serial) }
}
unsafe extern "C" fn on_xdg_configure(data: *mut c_void, s: P, serial: u32) {
    unsafe { abw_xdg_surface_ack_configure(s, serial) };
    unsafe { (*(data as *mut State)).configured = true };
}
unsafe extern "C" fn on_toplevel_configure(_d: *mut c_void, _t: P, _w: i32, _h: i32, _s: *mut c_void) {}
unsafe extern "C" fn on_close(data: *mut c_void, _t: P) {
    unsafe { (*(data as *mut State)).closed = true };
}

static REGISTRY: RegistryListener = RegistryListener { global: on_global, global_remove: on_global_remove };
static WM_BASE: WmBaseListener = WmBaseListener { ping: on_ping };
static XDG_SURFACE: XdgSurfaceListener = XdgSurfaceListener { configure: on_xdg_configure };
static TOPLEVEL: ToplevelListener = ToplevelListener { configure: on_toplevel_configure, close: on_close };

/// One fixed-size xdg_toplevel, drawn with cairo into a single shm buffer.
pub struct ShmWindow {
    display: *mut wl_display,
    surface: P,
    xdg_surface: P,
    toplevel: P,
    buffer: P,
    data: *mut u8,
    size: usize,
    width: i32,
    height: i32,
    state: Box<State>,
}

impl ShmWindow {
    /// Connect to $WAYLAND_DISPLAY and map a `w`x`h` window (logical
    /// pixels; the buffer is `scale` times that).
    pub fn open(title: &str, app_id: &str, w: i32, h: i32, scale: i32) -> Result<ShmWindow, String> {
        let display = unsafe { wl_display_connect(ptr::null()) };
        if display.is_null() {
            return Err("no Wayland display".into());
        }
        let mut state = Box::<State>::default();
        let sp = &mut *state as *mut State as *mut c_void;
        let registry = unsafe { abw_display_get_registry(display) };
        unsafe {
            wl_proxy_add_listener(registry, &REGISTRY as *const _ as *const c_void, sp);
            wl_display_roundtrip(display);
        }
        let (Some(c), Some(s), Some(x)) = (state.compositor, state.shm, state.wm_base) else {
            unsafe { wl_display_disconnect(display) };
            return Err("the compositor lacks wl_compositor, wl_shm or xdg_wm_base".into());
        };
        unsafe {
            let compositor = abw_registry_bind(registry, c.0, abw_compositor_iface, c.1.min(4));
            let shm = abw_registry_bind(registry, s.0, abw_shm_iface, 1);
            let wm_base = abw_registry_bind(registry, x.0, abw_xdg_wm_base_iface, 1);
            wl_proxy_add_listener(wm_base, &WM_BASE as *const _ as *const c_void, sp);

            let surface = abw_compositor_create_surface(compositor);
            let xdg_surface = abw_xdg_wm_base_get_xdg_surface(wm_base, surface);
            wl_proxy_add_listener(xdg_surface, &XDG_SURFACE as *const _ as *const c_void, sp);
            let toplevel = abw_xdg_surface_get_toplevel(xdg_surface);
            wl_proxy_add_listener(toplevel, &TOPLEVEL as *const _ as *const c_void, sp);
            let t = CString::new(title).unwrap_or_default();
            let a = CString::new(app_id).unwrap_or_default();
            abw_xdg_toplevel_set_title(toplevel, t.as_ptr());
            abw_xdg_toplevel_set_app_id(toplevel, a.as_ptr());
            abw_surface_commit(surface);
            while !state.configured && !state.closed {
                if wl_display_dispatch(display) < 0 {
                    break;
                }
            }
            if !state.configured {
                wl_display_disconnect(display);
                return Err("the toplevel was never configured".into());
            }

            let (bw, bh) = (w * scale, h * scale);
            let stride = bw * 4;
            let size = (stride * bh) as usize;
            let fd = aw_create_shm(size);
            if fd < 0 {
                wl_display_disconnect(display);
                return Err("aw_create_shm failed".into());
            }
            let data = libc::mmap(
                ptr::null_mut(),
                size,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                0,
            );
            if data == libc::MAP_FAILED {
                libc::close(fd);
                wl_display_disconnect(display);
                return Err("mmap of the shm buffer failed".into());
            }
            let pool = abw_shm_create_pool(shm, fd, size as i32);
            let buffer = abw_shm_pool_create_buffer(pool, 0, bw, bh, stride, WL_SHM_FORMAT_ARGB8888);
            abw_shm_pool_destroy(pool);
            libc::close(fd);
            abw_surface_set_buffer_scale(surface, scale);
            Ok(ShmWindow {
                display,
                surface,
                xdg_surface,
                toplevel,
                buffer,
                data: data as *mut u8,
                size,
                width: bw,
                height: bh,
                state,
            })
        }
    }

    /// Draw into the buffer: `f` gets a cairo surface over the shm memory,
    /// buffer-sized (logical size times the scale).
    pub fn draw(&mut self, f: impl FnOnce(&Surface)) {
        let cs = Surface(unsafe {
            cairo_image_surface_create_for_data(self.data, FORMAT_ARGB32, self.width, self.height, self.width * 4)
        });
        f(&cs);
        cs.flush();
    }

    /// Show what was drawn.
    pub fn present(&mut self) {
        unsafe {
            abw_surface_attach(self.surface, self.buffer, 0, 0);
            abw_surface_damage_buffer(self.surface, 0, 0, self.width, self.height);
            abw_surface_commit(self.surface);
            wl_display_flush(self.display);
        }
    }

    /// Serve events (pings, close) for `secs` seconds, or until the
    /// compositor closes the window. False if the connection failed.
    pub fn run_for(&mut self, secs: f64) -> bool {
        let deadline = Instant::now() + Duration::from_secs_f64(secs);
        let fd = unsafe { wl_display_get_fd(self.display) };
        while !self.state.closed {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            unsafe { wl_display_flush(self.display) };
            let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
            let n = unsafe { libc::poll(&mut p, 1, left.as_millis().min(1000) as c_int) };
            if n > 0 && unsafe { wl_display_dispatch(self.display) } < 0 {
                return false;
            }
        }
        true
    }

    pub fn closed(&self) -> bool {
        self.state.closed
    }
}

impl Drop for ShmWindow {
    fn drop(&mut self) {
        unsafe {
            abw_buffer_destroy(self.buffer);
            abw_xdg_toplevel_destroy(self.toplevel);
            abw_xdg_surface_destroy(self.xdg_surface);
            abw_surface_destroy(self.surface);
            libc::munmap(self.data as *mut c_void, self.size);
            wl_display_roundtrip(self.display);
            wl_display_disconnect(self.display);
        }
    }
}
