//! undertow: the compositor (main.swift beside it, PHASE6.md).
//!
//!   undertow bench-metronome [--hz N] [--frames N] [--surfaces N] [--assert-…]
//!   undertow bench-alloc     [--frames N] [--surfaces N]
//!   undertow headless        [--hz N] [--frames N] [--surfaces N] […]
//!   undertow run             […]   (usage() has every option)
//!
//! The binary IS the bench: flags in, a contract verdict out, a non-zero
//! exit when an assertion fails, so the gate stays in one place. Its output
//! lines are what the live scripts read, word for word as Swift wrote them.

use abyss_sys::mono;
use aquadraw::theme::Theme;
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashSet};
use std::process::exit;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use undertow::backend::{HeadlessSize, Kind, SharedOutput, WlrootsOutput, WlrootsSession};
use undertow::compositor::{Compositor, Options};
use undertow::displays::{format_setting, load_settings, problems, DisplayBox, DisplayLayout, DisplaySetting};
use undertow::metronome::{since, Config};
use undertow::output::{display_hz, recorder_capacity, run_is_unbounded, Output};
use undertow::output_management::commit_setting;
use undertow::scene::SurfaceScene;
use undertow::seat::{CursorImage, Desktop, Seat, SharedDesktop};
use undertow::synthetic::{SyntheticOutput, SyntheticScene};
use undertow::watches::announce_theme;
use undertow::{Conductor, FlightRecorder, Metronome};

// MARK: C2's precondition, measured: every allocation, counted.

/// Counts allocations while armed (bench-alloc). The plain Rust way to
/// what Swift interposed malloc for (CAllocProbe), with the same positive
/// control: a probe that cannot see a deliberate allocation is blind.
struct Counting;
static ARMED: AtomicBool = AtomicBool::new(false);
static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        if ARMED.load(Ordering::Relaxed) {
            ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        }
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        if ARMED.load(Ordering::Relaxed) {
            ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        }
        unsafe { System.realloc(p, l, n) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn arm() {
    ALLOCATIONS.store(0, Ordering::Relaxed);
    ARMED.store(true, Ordering::Relaxed);
}
fn disarm() -> u64 {
    ARMED.store(false, Ordering::Relaxed);
    ALLOCATIONS.load(Ordering::Relaxed)
}
fn probe_works() -> bool {
    arm();
    let v = std::hint::black_box(vec![0u8; 64]);
    drop(v);
    disarm() > 0
}

// MARK: output

fn out(s: &str) {
    use std::io::Write;
    let mut o = std::io::stdout().lock();
    let _ = writeln!(o, "{s}");
    let _ = o.flush();
}
fn err(s: &str) {
    eprintln!("{s}")
}
fn die(s: &str) -> ! {
    err(&format!("undertow: {s}"));
    exit(1)
}
fn usage() -> ! {
    err("usage: undertow bench-metronome [--hz N] [--frames N] [--surfaces N]
                                [--assert-missed N] [--assert-missed-permille N]
                                [--assert-cost-p99-us N]
       undertow bench-alloc     [--frames N] [--surfaces N]
       undertow headless        [--hz N] [--frames N] [--surfaces N]
                                [--width N] [--height N] [--verbose]
                                [--assert-missed-permille N]
                                [--assert-cost-p99-us N]
       undertow run             [--hz N] [--frames N] [--width N] [--height N]
                                [--output WxH[@X,Y]]...   (more headless outputs)
                                [--capture FILE.ppm] [--capture-early FILE.ppm]
                                [--assert-windows N] [--assert-surfaces N]
                                [--assert-layers N] [--assert-usable X,Y,WxH]
                                [--assert-missed N] [--config-dir DIR] [--verbose]
                                [--socket NAME] [--privileged-socket NAME]
                                [--display-sleep SECONDS]  (else energy.ini's minutes)
                                [--assert-c6-frames N] [--assert-c6-switches N]
                                           (C6: island switches, input to vblank)
                                [--stand-in-keyboard FIFO] (a keyboard with no keymap, for tests)
                                [--stand-in-vt FIFO]       (\"away\"/\"back\": a VT switch, for tests)");
    exit(2)
}

/// ns → "1234.56 us".
fn us(ns: u64) -> String {
    let h = ns * 100 / 1000;
    format!("{}.{:02} us", h / 100, h % 100)
}

/// rtprio(2)'s scale: 0 highest, 31 lowest; the middle leaves room above.
const REALTIME_PRIORITY: i32 = 16;

/// Another headless output: its size, and where, if asked.
type ExtraOutput = (i32, i32, Option<(i32, i32)>);

#[derive(Default)]
struct Opts {
    hz: u64,
    frames: u64,
    surfaces: usize,
    assert_missed: Option<usize>,
    assert_missed_permille: Option<usize>,
    assert_c6_frames: Option<usize>,
    assert_c6_switches: Option<usize>,
    assert_cost_p99_us: Option<u64>,
    width: i32,
    height: i32,
    extra: Vec<ExtraOutput>,
    verbose: bool,
    capture: Option<String>,
    trace: Option<String>,
    realtime: bool,
    capture_early: Option<String>,
    assert_windows: Option<usize>,
    assert_surfaces: Option<u64>,
    assert_layers: Option<usize>,
    assert_usable: Option<String>,
    config_dir: Option<String>,
    display_sleep: Option<f64>,
    stand_in_keyboard: Option<String>,
    stand_in_vt: Option<String>,
    socket: Option<String>,
    privileged_socket: Option<String>,
    auto: bool,
    asserts: Vec<String>,
}

fn parse(args: &[String]) -> Opts {
    let mut o = Opts { hz: 240, frames: 1200, surfaces: 512, width: 1920, height: 1080, realtime: true, ..Opts::default() };
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        let mut value = |name: &str| -> String {
            i += 1;
            args.get(i).cloned().unwrap_or_else(|| die(&format!("{name} needs a value")))
        };
        fn num<T: std::str::FromStr>(v: String, what: &str) -> T {
            v.parse().unwrap_or_else(|_| die(&format!("{what} wants a number")))
        }
        if a.starts_with("--assert-") {
            o.asserts.push(a.to_owned());
        }
        match a {
            "--hz" => o.hz = num(value(a), "--hz"),
            "--frames" => o.frames = num(value(a), "--frames"),
            "--surfaces" => o.surfaces = num(value(a), "--surfaces"),
            "--assert-missed" => o.assert_missed = value(a).parse().ok(),
            "--assert-c6-frames" => o.assert_c6_frames = value(a).parse().ok(),
            "--assert-c6-switches" => o.assert_c6_switches = value(a).parse().ok(),
            "--assert-missed-permille" => o.assert_missed_permille = value(a).parse().ok(),
            "--assert-cost-p99-us" => o.assert_cost_p99_us = value(a).parse().ok(),
            "--width" => o.width = num(value(a), "--width"),
            "--height" => o.height = num(value(a), "--height"),
            // Another headless output (P14.7a): WxH, to the right of the
            // last, or WxH@X,Y, placed there.
            "--output" => {
                let v = value(a);
                let (wh, at) = v.split_once('@').map_or((v.as_str(), None), |(w, a)| (w, Some(a)));
                let bad = || die(&format!("--output wants WxH or WxH@X,Y, not '{v}'"));
                let (w, h) = wh.split_once('x').and_then(|(w, h)| Some((w.parse::<i32>().ok()?, h.parse::<i32>().ok()?))).filter(|(w, h)| *w > 0 && *h > 0).unwrap_or_else(bad);
                let at = at.map(|a| a.split_once(',').and_then(|(x, y)| Some((x.parse().ok()?, y.parse().ok()?))).unwrap_or_else(bad));
                o.extra.push((w, h, at));
            }
            "--verbose" => o.verbose = true,
            "--capture" => o.capture = Some(value(a)),
            "--trace" => o.trace = Some(value(a)),
            "--no-realtime" => o.realtime = false,
            "--capture-early" => o.capture_early = Some(value(a)),
            "--assert-windows" => o.assert_windows = value(a).parse().ok(),
            "--assert-surfaces" => o.assert_surfaces = value(a).parse().ok(),
            "--assert-layers" => o.assert_layers = value(a).parse().ok(),
            "--assert-usable" => o.assert_usable = Some(value(a)),
            "--config-dir" => o.config_dir = Some(value(a)),
            "--display-sleep" => o.display_sleep = value(a).parse().ok(),
            "--stand-in-keyboard" => o.stand_in_keyboard = Some(value(a)),
            "--stand-in-vt" => o.stand_in_vt = Some(value(a)),
            "--socket" => o.socket = Some(value(a)),
            "--privileged-socket" => o.privileged_socket = Some(value(a)),
            "--backend" => match value(a).as_str() {
                "headless" => o.auto = false,
                "auto" => o.auto = true,
                b => die(&format!("--backend is headless or auto, not '{b}'")),
            },
            "-h" | "--help" => usage(),
            _ => die(&format!("unknown option '{a}'")),
        }
        i += 1;
    }
    o
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(mode) = args.first().cloned() else { usage() };
    let mut o = parse(&args[1..]);
    if o.hz == 0 {
        die("--hz must be positive, --frames must not be negative");
    }
    let unbounded = run_is_unbounded(o.frames);
    // **An assertion that never runs is worse than no assertion**: every
    // --assert-* is checked after the loop, which an unbounded run never
    // leaves (§2.37's shape, in the arguments).
    if unbounded {
        if let Some(a) = o.asserts.first() {
            die(&format!("{a} needs a frame count: an assertion after an unbounded run never runs"));
        }
        if o.capture.is_some() || o.capture_early.is_some() {
            die("--capture needs a frame count: an unbounded run never reaches the end");
        }
    }
    match mode.as_str() {
        "bench-metronome" => bench_metronome(&o),
        "bench-alloc" => bench_alloc(&o),
        "headless" => headless(&o),
        "run" => run(&mut o),
        _ => usage(),
    }
}

fn period_ns(o: &Opts) -> u64 {
    1_000_000_000 / o.hz
}

fn warmup_for(frames: u64, unbounded: bool) -> u64 {
    if unbounded { 240 } else { (frames / 8).clamp(16, 240) }
}

// MARK: C1 cadence

fn bench_metronome(o: &Opts) {
    let p = period_ns(o);
    let mut output = SyntheticOutput::new(p, 200_000);
    let mut scene = SyntheticScene::new(o.surfaces, (1920, 1080));
    let mut rec = FlightRecorder::new(o.frames.max(1) as usize);
    let mut m = Metronome::new(p, Config::default());
    // Warm up into a throwaway recorder: the margin loop discovers the
    // display's commit latency by missing once or twice, which is the
    // process's first frames, not the cadence C1 is about.
    let warmup = warmup_for(o.frames, false);
    m.run(warmup, &mut output, &mut scene, &mut FlightRecorder::new(warmup as usize));
    let began = mono::now();
    m.run(o.frames, &mut output, &mut scene, &mut rec);
    let elapsed = since(began, mono::now());
    let missed = rec.missed_count();
    out(&format!("undertow bench-metronome — {}Hz, {} frames, {} surfaces (after {warmup} warmup)", o.hz, o.frames, o.surfaces));
    out(&format!("  wall clock        {} ms  (nominal {} ms)", elapsed / 1_000_000, o.frames * p / 1_000_000));
    out(&format!("  period estimate   {}  (nominal {}, {} samples)", us(m.predictor.period_ns), us(p), m.predictor.samples));
    out(&format!("  latch margin      {}", us(m.margin.margin_ns())));
    let (p50, p99, p999) = (rec.cost_percentile_ns(50.0), rec.cost_percentile_ns(99.0), rec.cost_percentile_ns(99.9));
    out(&format!("  composite cost    p50 {}   p99 {}   p99.9 {}", us(p50), us(p99), us(p999)));
    let permille = if rec.retained() > 0 { missed * 1000 / rec.retained() } else { 0 };
    out(&format!("  missed flips      {missed} of {}  ({permille} per mille)", rec.retained()));
    out(&format!("  degraded frames   {}", rec.degraded_count()));
    let mut failed = false;
    if let Some(l) = o.assert_missed
        && missed > l
    {
        err(&format!("FAIL C1: {missed} missed flips, limit {l}"));
        failed = true;
    }
    if let Some(l) = o.assert_missed_permille {
        let allowed = o.frames as usize * l / 1000;
        if missed > allowed {
            err(&format!("FAIL C1: {missed} missed flips of {} ({permille} per mille), limit {l} per mille = {allowed}", o.frames));
            failed = true;
        }
    }
    if let Some(l) = o.assert_cost_p99_us
        && p99 / 1000 > l
    {
        err(&format!("FAIL C1: composite cost p99 {}, limit {l}.00 us", us(p99)));
        failed = true;
    }
    if failed {
        exit(1)
    }
    out("  verdict           ok");
}

// MARK: C2's precondition: no allocation on the present loop

fn bench_alloc(o: &Opts) {
    // The positive control first, and fatal: a blind probe reports a
    // comfortable zero, indistinguishable from success (HANDOFF §2.37).
    if !probe_works() {
        die("the allocation probe is BLIND — it did not see a deliberate allocation.\nNothing measured here would mean anything.");
    }
    out(&format!("undertow bench-alloc — {} frames, {} surfaces", o.frames, o.surfaces));
    out("  probe             live (positive control saw its own allocations)");
    let p = period_ns(o);
    let mut output = SyntheticOutput::new(p, 200_000);
    let mut scene = SyntheticScene::new(o.surfaces, (1920, 1080));
    let mut rec = FlightRecorder::new(1024);
    // Free-run: allocations are measured, not cadence.
    let mut m = Metronome::new(p, Config { free_run: true, ..Config::default() });
    // Warm every path once: first touches are legitimately one-off.
    m.run(64, &mut output, &mut scene, &mut rec);
    arm();
    m.run(o.frames, &mut output, &mut scene, &mut rec);
    let n = disarm();
    out(&format!("  frames measured   {}", o.frames));
    out(&format!("  allocations       {n}"));
    if n != 0 {
        err(&format!("FAIL C2: the present loop allocated {n} times in {} frames.\nAn allocation on the present path is a lock a client can contend and a\nlatency spike the contract does not permit (PLAN.md risk 4).", o.frames));
        exit(1);
    }
    out("  verdict           ok — the present loop is allocation-free");
}

// MARK: the compositor, on real wlroots

fn headless(o: &Opts) {
    let p = period_ns(o);
    let session = WlrootsSession::headless(1, o.width, o.height, (o.hz * 1000) as i32, o.verbose).unwrap_or_else(|e| die(&e.to_string()));
    let Some(w) = session.outputs().first().copied() else { die("no output") };
    let mut output = WlrootsOutput::new(w, &session);
    let mut scene = SyntheticScene::new(o.surfaces, (o.width, o.height));
    let mut rec = FlightRecorder::new(o.frames.max(1) as usize);
    let mut m = Metronome::new(output.period_hint_ns(), Config::default());
    out(&format!("undertow headless — {} {}x{} @ {}Hz, {} frames, {} surfaces", output.name, output.width(), output.height(), o.hz, o.frames, o.surfaces));
    let warmup = warmup_for(o.frames, run_is_unbounded(o.frames));
    m.run(warmup, &mut output, &mut scene, &mut FlightRecorder::new(warmup as usize));
    let began = mono::now();
    m.run(o.frames, &mut output, &mut scene, &mut rec);
    let elapsed = since(began, mono::now());
    let missed = rec.missed_count();
    let p99 = rec.cost_percentile_ns(99.0);
    let permille = if rec.retained() > 0 { missed * 1000 / rec.retained() } else { 0 };
    let presented = rec.percentile(50.0, |r| r.actual_vblank);
    out(&format!("  wall clock        {} ms  (nominal {} ms)", elapsed / 1_000_000, o.frames * p / 1_000_000));
    out(&format!("  period estimate   {}  (nominal {}, {} samples)", us(m.predictor.period_ns), us(p), m.predictor.samples));
    out(&format!("  latch margin      {}", us(m.margin.margin_ns())));
    out(&format!("  composite cost    p50 {}   p99 {}", us(rec.cost_percentile_ns(50.0)), us(p99)));
    out(&format!("  missed flips      {missed} of {}  ({permille} per mille)", rec.retained()));
    // Frames really reached the display: wlroots reports a present only for a
    // commit it presented.
    out(&format!("  presented frames  {}", if presented > 0 { "yes" } else { "NO — no present events arrived" }));
    // Which clock the cadence rests on: a headless output reports none, so
    // it is paced against its nominal grid, and the bench says so.
    out(&format!("  vblank source     {}", if output.saw_hardware_clock { "hardware clock (driver-measured timestamps)" } else { "nominal grid — this backend reports no hardware clock" }));
    let mut failed = false;
    if presented == 0 {
        err("FAIL: no present events — the compositor committed frames that never landed");
        failed = true;
    }
    if m.predictor.samples == 0 {
        err("FAIL: the predictor never received a sample — flip feedback is not reaching it");
        failed = true;
    }
    if let Some(l) = o.assert_missed_permille
        && permille > l
    {
        err(&format!("FAIL C1: {missed} missed of {} ({permille} per mille), limit {l}", o.frames));
        failed = true;
    }
    if let Some(l) = o.assert_cost_p99_us
        && p99 / 1000 > l
    {
        err(&format!("FAIL C1: composite cost p99 {}, limit {l}.00 us", us(p99)));
        failed = true;
    }
    if failed {
        exit(1)
    }
    out("  verdict           ok");
}

// MARK: the compositor, hosting real clients

type Rig = (Vec<Rc<RefCell<WlrootsOutput>>>, Vec<Rc<RefCell<Desktop<undertow::compositor::CompositorWorld>>>>);

fn run(o: &mut Opts) {
    // `--backend auto`: DRM on metal, a nested window, whatever this is.
    // Headless stays the default: the build VM, and C1–C5 reproducible.
    let kind = if o.auto {
        Kind::Auto
    } else {
        let mut sizes = vec![HeadlessSize::new(o.width, o.height)];
        sizes.extend(o.extra.iter().map(|(w, h, _)| HeadlessSize::new(*w, *h)));
        Kind::Headless { sizes, refresh_mhz: (o.hz * 1000) as i32 }
    };
    let session = Rc::new(WlrootsSession::new(kind, o.verbose).unwrap_or_else(|e| die(&e.to_string())));
    // **On a real backend the display's size and rate are the truth**, not
    // the command line's (the first run on a 60 Hz panel announced 240 Hz).
    if o.auto
        && let Some(first) = session.outputs().first()
    {
        o.width = first.width();
        o.height = first.height();
        o.hz = display_hz(first.refresh(), o.hz);
    }
    // Where each output sits: displays.ini's choice wins (P14.7b), else the
    // first at the origin and each --output where asked, or to the right.
    let saved = load_settings(o.config_dir.as_deref());
    let mut boxes: Vec<DisplayBox> = vec![];
    let mut next_x = 0;
    for (i, w) in session.outputs().iter().enumerate() {
        let name = w.name();
        if let Some(s) = saved.get(&name)
            && commit_setting(s, *w)
        {
            let b = s.display_box();
            err(&format!("undertow: displays.ini: {name} {}", format_setting(s)));
            next_x = next_x.max(b.x + b.width);
            boxes.push(b);
            continue;
        }
        let (mut x, mut y) = (next_x, 0);
        if !o.auto && i > 0 && let Some((_, _, Some(at))) = o.extra.get(i - 1) {
            (x, y) = *at;
        }
        boxes.push(DisplayBox::new(&name, x, y, w.width(), w.height()));
        next_x = next_x.max(x + w.width());
    }
    let settings: Vec<DisplaySetting> = boxes.iter().map(|b| DisplaySetting { name: b.name.clone(), enabled: true, mode_width: b.width, mode_height: b.height, refresh_milli_hz: 0, x: b.x, y: b.y, scale: 1.0 }).collect();
    if !problems(&settings).is_empty() {
        err("undertow: displays.ini does not fit these outputs; placing them side by side");
        let row: Vec<(&str, i32, i32)> = boxes.iter().map(|b| (b.name.as_str(), b.width, b.height)).collect();
        boxes = DisplayLayout::row(&row).displays;
    }
    let layout = DisplayLayout { displays: boxes };
    // The theme the toolkit draws with, from --config-dir, and said.
    let mut runner = aquadraw::scene::runner(1);
    let mut theme = Theme::default();
    announce_theme(&theme.load_current(o.config_dir.as_deref(), runner.as_mut()));
    let opts = Options { config_dir: o.config_dir.as_deref(), socket_name: o.socket.as_deref(), privileged_socket: o.privileged_socket.as_deref() };
    let compositor = Compositor::new(session.clone(), layout.clone(), opts, theme, runner).unwrap_or_else(|e| die(&e.to_string()));
    compositor.watch_appearance();
    compositor.watch_islands();
    let seat = Seat::new(&compositor).unwrap_or_else(|e| die(&e.to_string()));
    // The session's layout, before any keyboard attaches (T.2).
    seat.follow_session_layout();
    if let Some(f) = &o.stand_in_keyboard
        && !seat.add_stand_in_keyboard(f)
    {
        die(&format!("could not make a stand-in keyboard reading {f}"));
    }
    // **One rig per output** (P14.7a): its scene, its metronome, its recorder.
    let (outs, desks): Rig = layout
        .displays
        .iter()
        .map(|d| {
            let w = session.output_named(&d.name).unwrap_or_else(|| die(&format!("no output {}", d.name)));
            let out = Rc::new(RefCell::new(WlrootsOutput::new(w, &session)));
            let desk = Rc::new(RefCell::new(Desktop { scene: SurfaceScene::new(compositor.world(), d, compositor.metrics.get(), 256), seat: Some(seat.clone()) }));
            out.borrow_mut().set_painter(desk.clone());
            (out, desk)
        })
        .unzip();
    if outs.is_empty() {
        die("no output")
    }
    let mut recorders: Vec<FlightRecorder> = outs.iter().map(|_| FlightRecorder::new(recorder_capacity(o.frames))).collect();
    // Display sleep (U.9): all outputs off after the timeout, on at input.
    compositor.start_display_sleep(o.display_sleep);
    {
        let outs = outs.clone();
        compositor.display_sleep.borrow().as_ref().unwrap().on_change(move |asleep| {
            for x in &outs {
                x.borrow_mut().set_asleep(asleep)
            }
            out(if asleep { "displays asleep" } else { "displays awake" });
        });
    }
    let mut conductor = Conductor::new(outs.iter().map(|x| SharedOutput(x.clone())).collect(), desks.iter().map(|d| SharedDesktop(d.clone())).collect(), Config::default());
    // **Retunes wait for the conductor to be free**: the hooks below run
    // inside its wait, which holds it (Swift's exclusivity check ended the
    // process the first time a VT came back).
    let retunes: Rc<RefCell<Vec<usize>>> = Rc::default();
    {
        let (outs, desks, retunes) = (outs.clone(), desks.clone(), retunes.clone());
        compositor.on_outputs_applied(move |layout| {
            for (i, x) in outs.iter().enumerate() {
                let name = x.borrow().name.clone();
                if let Some(d) = layout.named(&name) {
                    desks[i].borrow_mut().scene.show(d)
                }
                if x.borrow_mut().refresh_period() {
                    retunes.borrow_mut().push(i)
                }
            }
            out(&format!("outputs {}", layout.summary()));
        });
    }
    // **Outputs that go and come back** (P16): a VT switch destroys every DRM
    // output and the way back announces them again. The rig stays; only the
    // wlroots output under it is let go and taken up again, by name.
    {
        let (c, gone) = (Rc::downgrade(&compositor), outs.clone());
        session.on_output_removed(move |w| {
            if let Some(c) = c.upgrade() {
                c.output_lost(w)
            }
            for x in &gone {
                let bound = x.borrow().is_bound_to(w);
                if bound {
                    x.borrow_mut().detach();
                    out(&format!("output {} gone", x.borrow().name));
                }
            }
        });
        let (c, back, retunes, dir) = (Rc::downgrade(&compositor), outs.clone(), retunes.clone(), o.config_dir.clone());
        session.on_output_added(move |w| {
            let name = w.name();
            if let Some(s) = load_settings(dir.as_deref()).get(&name) {
                commit_setting(s, w);
            }
            let mut known = false;
            for (i, x) in back.iter().enumerate() {
                if x.borrow().name == name {
                    x.borrow_mut().attach(w);
                    retunes.borrow_mut().push(i);
                    known = true;
                    out(&format!("output {name} back"));
                }
            }
            if known {
                if let Some(c) = c.upgrade() {
                    c.output_returned(w)
                }
            } else {
                err(&format!("undertow: a new output {name} — not used until the next session"));
            }
        });
    }
    if let Some(f) = &o.stand_in_vt
        && !session.add_stand_in_vt(f)
    {
        die(&format!("could not make a stand-in VT reading {f} (headless only)"));
    }
    // The socket, before the loop: a harness reads one line and knows where
    // to point a client, rather than racing a sleep against our startup.
    out(&format!("WAYLAND_DISPLAY={}", compositor.socket_name));
    if let Some(p) = &compositor.privileged_socket_name {
        out(&format!("WAYLAND_PRIVILEGED={p}"));
    }
    {
        let o0 = outs[0].borrow();
        err(&format!("undertow: {} {}x{} @ {}Hz (period {}) on {}", o0.name, o0.width(), o0.height(), o.hz, us(o0.period_hint_ns()), compositor.socket_name));
    }
    out(&format!("outputs {}", compositor.layout.borrow().summary()));
    // **Real-time priority, if this user may have it** (PHASE4 §5.13).
    if !o.realtime {
        out("realtime=declined");
    } else {
        match abyss_sys::platform::request_realtime(REALTIME_PRIORITY) {
            Ok(()) => {
                err(&format!("undertow: real-time priority {REALTIME_PRIORITY}"));
                out("realtime=granted");
            }
            Err(e) => {
                let why = if e.raw_os_error() == Some(libc::EPERM) { "not permitted (root, or group realtime with mac_priority loaded)".to_owned() } else { e.to_string() };
                err(&format!("undertow: running without real-time priority — {why}"));
                out("realtime=refused");
            }
        }
    }
    let apply_retunes = |conductor: &mut Conductor<SharedOutput, SharedDesktop<_>>| {
        let rs = std::mem::take(&mut *retunes.borrow_mut());
        for i in rs {
            let p = outs[i].borrow().period_hint_ns();
            conductor.retune(i, p);
        }
    };
    // Warm up into throwaway recorders: a healthy baseline is exactly zero
    // missed frames, which lets the C2 gate be a flat zero.
    let warmup = warmup_for(o.frames, unbounded_of(o));
    let mut warm: Vec<FlightRecorder> = outs.iter().map(|_| FlightRecorder::new(warmup as usize)).collect();
    for _ in 0..warmup as usize * outs.len() {
        conductor.serve_next(&mut warm);
        apply_retunes(&mut conductor);
        compositor.end_frame();
    }
    let mut rep = Reported::default();
    let (mut settle, mut early_done, mut drawn) = (-1i32, false, 0u64);
    while unbounded_of(o) || drawn < o.frames {
        rep.report(&compositor, &seat, &outs, &desks, &conductor);
        // Before the frame: a display just asleep is not drawn.
        compositor.display_sleep_tick();
        if conductor.serve_next(&mut recorders) {
            drawn += 1;
        }
        apply_retunes(&mut conductor);
        // Which outputs each surface is on (U.10), off the present path.
        compositor.update_surface_outputs();
        // Release clients to draw the next frame, and push events out.
        compositor.end_frame();
        // The early capture fires a few frames after the FIRST window maps:
        // a synchronisation point, not a sleep long enough to usually work.
        if let Some(early) = &o.capture_early
            && !early_done
        {
            if settle < 0 {
                if !compositor.mapped_toplevels().is_empty() {
                    settle = 20
                }
            } else if settle > 0 {
                settle -= 1
            } else {
                early_done = true;
                if !outs[0].borrow_mut().capture_ppm(early) {
                    die(&format!("could not write {early}"));
                }
                err(&format!("undertow: wrote {early} (first window has drawn)"));
            }
        }
    }
    if let Some(path) = &o.capture {
        if !outs[0].borrow_mut().capture_ppm(path) {
            die(&format!("could not write {path}"));
        }
        err(&format!("undertow: wrote {path}"));
        // Every other display beside it: shot.ppm → shot.HEADLESS-2.ppm.
        for x in outs.iter().skip(1) {
            let base = path.strip_suffix(".ppm").unwrap_or(path);
            let p = format!("{base}.{}.ppm", x.borrow().name);
            if !x.borrow_mut().capture_ppm(&p) {
                die(&format!("could not write {p}"));
            }
            err(&format!("undertow: wrote {p}"));
        }
    }
    summary(o, &compositor, &seat, &outs, &desks, &conductor, &recorders);
}

fn unbounded_of(o: &Opts) -> bool {
    run_is_unbounded(o.frames)
}

/// What has been said, so each line is said only when it changes: an
/// unbounded run never reaches the summary, and the tests that need these
/// numbers most are exactly those runs.
#[derive(Default)]
struct Reported {
    ops: String,
    theme_reloads: u64,
    /// By window, not by place key: two windows can share a key, and a new
    /// one reopened where the last of that key was must still be said
    /// (Swift's per-key map hid it, once places were really remembered).
    geometry: BTreeMap<u32, String>,
    stack: String,
    text_input: String,
    constraints: String,
    cursor: String,
    idle: String,
    sync: String,
    layout: String,
    hidden: Option<u64>,
    lock: String,
    primary: u64,
    selections: u64,
    rasterisations: u64,
    frame_clicks: u64,
    keybinds: u64,
    drags: u64,
    islands: String,
    presented_at: u64,
    c6: Vec<usize>,
    window_islands: BTreeMap<String, i32>,
    jails: HashSet<u32>,
}

impl Reported {
    fn line(slot: &mut String, line: String) {
        if *slot != line {
            out(&line);
            *slot = line;
        }
    }

    fn report(&mut self, c: &Rc<Compositor>, seat: &Rc<Seat>, outs: &[Rc<RefCell<WlrootsOutput>>], desks: &[Rc<RefCell<Desktop<undertow::compositor::CompositorWorld>>>], conductor: &Conductor<SharedOutput, SharedDesktop<undertow::compositor::CompositorWorld>>) {
        Reported::line(&mut self.ops, format!("resizes-started={} maximizes={} minimizes={} snaps={} lowers={}", c.resizes_started.get(), c.maximize_count.get(), c.minimize_count.get(), c.snap_count.get(), c.lower_count.get()));
        if c.theme_reloads.get() != self.theme_reloads {
            self.theme_reloads = c.theme_reloads.get();
            out(&format!("theme-reloads={} generation={}", self.theme_reloads, c.theme.borrow().generation));
        }
        let ts = c.toplevels.borrow().clone();
        // A window that unmapped is forgotten: mapped again, it is said again.
        self.geometry.retain(|id, _| ts.iter().any(|t| t.id == *id && t.mapped.get()));
        for t in ts.iter().filter(|t| t.mapped.get()) {
            let key = t.place_key().unwrap_or_else(|| "?".into());
            let flags = if t.minimized.get() { " min" } else if t.maximized.get() { " max" } else { "" };
            // The key with the geometry: a window renamed in place (a pane's
            // title) is said again, as its tile is renamed.
            let line = format!("{key} {},{} {}x{}{flags}", t.x.get(), t.y.get(), t.width(), t.height());
            if self.geometry.get(&t.id) != Some(&line) {
                out(&format!("window {line}"));
                self.geometry.insert(t.id, line);
            }
        }
        let stack: Vec<String> = ts.iter().filter(|t| t.mapped.get()).map(|t| t.place_key().unwrap_or_else(|| "?".into())).collect();
        Reported::line(&mut self.stack, format!("stack={}", stack.join(" ")));
        // Frames actually sent, once a second (M.1: a still screen sends none).
        if since(self.presented_at, mono::now()) >= 1_000_000_000 {
            self.presented_at = mono::now();
            out(&format!("presented {}", outs.iter().map(|x| x.borrow().commits_made).sum::<u64>()));
        }
        let isl: Vec<String> = c.layout.borrow().displays.iter().map(|d| format!("{}={}", d.name, c.active_island(&d.name))).collect();
        Reported::line(&mut self.islands, format!("islands {}", isl.join(" ")));
        // C6 (P13.2): each switch, input to the vblank that showed it.
        if self.c6.len() != conductor.metronomes.len() {
            self.c6 = vec![0; conductor.metronomes.len()];
        }
        for (i, m) in conductor.metronomes.iter().enumerate() {
            let n = m.c6.count;
            for k in self.c6[i]..n {
                if n - k <= m.c6.retained() {
                    let (frames, ns) = m.c6.sample(m.c6.retained() - (n - k));
                    out(&format!("island-commit {} frames={frames} us={}", outs[i].borrow().name, ns / 1000));
                }
            }
            self.c6[i] = n;
        }
        // A window from a jail (P18.3), said once per window.
        let live: HashSet<u32> = ts.iter().filter(|t| t.mapped.get()).map(|t| t.id).collect();
        self.jails.retain(|id| live.contains(id));
        for t in ts.iter().filter(|t| t.mapped.get()) {
            if self.jails.contains(&t.id) {
                continue;
            }
            let j = c.menus.borrow().as_ref().and_then(|m| m.jail(t.surface));
            if let Some((engine, app, instance)) = j {
                self.jails.insert(t.id);
                out(&format!("window-jail {} engine={engine} app={app} instance={instance}", t.place_key().unwrap_or_else(|| "?".into())));
            }
        }
        for t in ts.iter().filter(|t| t.mapped.get()) {
            let key = t.place_key().unwrap_or_else(|| "?".into());
            if self.window_islands.get(&key) != Some(&t.island.get()) {
                out(&format!("window-island {key} {}", t.island.get()));
                self.window_islands.insert(key, t.island.get());
            }
        }
        // The text-input relay's counts (U.5): events, never text.
        if let Some(ti) = &seat.text_input {
            Reported::line(&mut self.text_input, format!("text-input enters={} activations={} commits-relayed={} keys-grabbed={}", ti.enters.get(), ti.activations.get(), ti.commits_relayed.get(), ti.keys_grabbed.get()));
        }
        if let Some(pc) = &seat.pointer_constraints {
            Reported::line(&mut self.constraints, format!("pointer-constraints locks={} confines={} held={} warps={} active={}", pc.locks.get(), pc.confines.get(), pc.held.get(), pc.warps.get(), if pc.is_active() { "yes" } else { "none" }));
        }
        let image = match &*seat.cursor_image.borrow() {
            CursorImage::Shape(n) => format!("shape:{n}"),
            CursorImage::Client => "client".into(),
            CursorImage::Hidden => "hidden".into(),
        };
        Reported::line(&mut self.cursor, format!("cursor {image} requests={} refused={} rasterised={}", seat.cursor_requests.get(), seat.cursor_refused.get(), seat.cursor_images.borrow().rasterisations));
        if let Some(ds) = &*c.display_sleep.borrow() {
            Reported::line(&mut self.idle, format!("display-sleep {} sleeps={} wakes={} inhibited={}", if ds.asleep() { "asleep" } else { "awake" }, ds.sleeps.get(), ds.wakes.get(), if ds.inhibited() { "yes" } else { "no" }));
        }
        {
            let l = c.lock.borrow();
            let state = if l.abandoned() { "abandoned" } else if l.locked { "locked" } else { "unlocked" };
            let line = format!("session-lock {state} locks={} unlocks={} refused={} abandonments={} grabs-broken={}", l.locks, l.unlocks, l.refused, l.abandonments, seat.grabs_broken.get());
            drop(l);
            Reported::line(&mut self.lock, line);
        }
        if self.hidden != Some(c.hidden_commits.get()) {
            self.hidden = Some(c.hidden_commits.get());
            out(&format!("hidden-commits={}", c.hidden_commits.get()));
        }
        Reported::line(&mut self.layout, format!("keyboard-layout {} changes={}", seat.layout_description.borrow(), seat.layout_changes.get()));
        if c.explicit_sync.borrow().offered {
            let waits: u64 = desks.iter().map(|d| d.borrow().scene.acquire_waits).sum();
            Reported::line(&mut self.sync, format!("explicit-sync releases-armed={} acquire-waits={waits}", c.explicit_sync.borrow().releases_armed.get()));
        }
        let counter = |slot: &mut u64, now: u64, name: &str| {
            if *slot != now {
                *slot = now;
                out(&format!("{name}={now}"));
            }
        };
        counter(&mut self.primary, seat.primary_selections_accepted.get(), "primary-selections-accepted");
        counter(&mut self.selections, seat.selections_accepted.get(), "selections-accepted");
        counter(&mut self.rasterisations, c.frames.borrow().rasterisations, "frame-rasterisations");
        counter(&mut self.frame_clicks, seat.frame_clicks.get(), "frame-clicks");
        counter(&mut self.keybinds, seat.keybinds_fired.get(), "keybinds-fired");
        counter(&mut self.drags, seat.drags_started.get(), "drags-started");
    }
}

#[allow(clippy::too_many_arguments)]
fn summary(o: &Opts, c: &Rc<Compositor>, seat: &Rc<Seat>, outs: &[Rc<RefCell<WlrootsOutput>>], desks: &[Rc<RefCell<Desktop<undertow::compositor::CompositorWorld>>>], conductor: &Conductor<SharedOutput, SharedDesktop<undertow::compositor::CompositorWorld>>, recorders: &[FlightRecorder]) {
    let m = &conductor.metronomes[0];
    let rec = &recorders[0];
    let o0 = outs[0].borrow();
    let windows = c.mapped_toplevels().len();
    out(&format!("windows={windows}"));
    out(&format!("surfaces-composited={}", desks[0].borrow().scene.count));
    let (cx, cy) = seat.cursor.get();
    out(&format!("cursor={},{}", cx as i64, cy as i64));
    out(&format!("focused={}", if c.focused().is_some() { "yes" } else { "no" }));
    out(&format!("restored={}", c.restored_count.get()));
    for t in c.mapped_toplevels() {
        out(&format!("window {} at {},{}", t.place_key().unwrap_or_else(|| "?".into()), t.x.get(), t.y.get()));
    }
    // Everyone ever here, including clients since gone: the guest list.
    for k in c.ever_mapped.borrow().iter() {
        out(&format!("mapped {k}"));
    }
    // The positive controls (P6.5, P9.1, P9.3, §6.1, P9.4).
    out(&format!("surfaces-created={}", c.surfaces_created.get()));
    out(&format!("selections-accepted={}", seat.selections_accepted.get()));
    out(&format!("drags-started={}", seat.drags_started.get()));
    out(&format!("keybinds-fired={}", seat.keybinds_fired.get()));
    out(&format!("frame-clicks={}", seat.frame_clicks.get()));
    out(&format!("frame-rasterisations={}", c.frames.borrow().rasterisations));
    out(&format!("resizes-started={}", c.resizes_started.get()));
    out(&format!("maximizes={}", c.maximize_count.get()));
    out(&format!("minimizes={}", c.minimize_count.get()));
    out(&format!("snaps={}", c.snap_count.get()));
    out(&format!("layers={} of {}", c.mapped_layers().len(), c.layers.borrow().len()));
    // The usable area: the only observable proof an exclusive zone was
    // honoured (§2.26).
    let u = c.usable_area();
    out(&format!("usable={},{},{}x{}", u.x, u.y, u.width, u.height));
    for d in c.layout.borrow().displays.iter().skip(1) {
        let a = c.usable.borrow().get(&d.name).copied().unwrap_or(d.rect());
        out(&format!("usable {}={},{},{}x{}", d.name, a.x, a.y, a.width, a.height));
    }
    out(&format!("wake-late-p99-us={}", rec.percentile(99.0, |r| r.wake_late_ns) / 1000));
    out(&format!("composite-p99-us={}", rec.cost_percentile_ns(99.0) / 1000));
    out(&format!("margin-us={}", m.margin.margin_ns() / 1000));
    out(&format!("missed={} of {}", rec.missed_count(), rec.retained()));
    // **The margin's parts**, and whether it is pinned at its ceiling (a loop
    // that has given up): a large number and a pinned one look the same.
    out(&format!("margin-wake-us={}", m.margin.wake_high_ns / 1000));
    out(&format!("margin-cost-us={}", m.margin.cost_high_ns / 1000));
    out(&format!("margin-commit-us={}", m.margin.commit_high_ns / 1000));
    out(&format!("margin-vblank-us={}", m.margin.vblank_high_ns / 1000));
    out(&format!("margin-safety-us={}", m.margin.safety_ns / 1000));
    out(&format!("margin-pinned={}", if m.margin.margin_ns() >= m.margin.ceil_ns { "yes" } else { "no" }));
    out(&format!("period-us={}", o0.period_hint_ns() / 1000));
    // **What the numbers were measured against** (§2.48), and whose clock.
    out(&format!("vblank-source={}", if o0.saw_hardware_clock { "hardware" } else { "nominal" }));
    out(&format!("backend={}", o0.backend_name()));
    out(&format!("commits-refused={} of {}", o0.commits_refused, o0.commits_made + o0.commits_refused));
    let (n, late1, late_half, worst) = o0.deliveries();
    out(&format!("present-delivery late>1ms={late1} late>half-period={late_half} of {n}, worst={}us", worst / 1000));
    if let Some(p) = &o.trace {
        write_trace(rec, p)
    }
    for (i, x) in outs.iter().enumerate().skip(1) {
        let x = x.borrow();
        out(&format!("output {} missed={} of {} period-us={} composite-p99-us={}", x.name, recorders[i].missed_count(), recorders[i].retained(), x.period_hint_ns() / 1000, recorders[i].cost_percentile_ns(99.0) / 1000));
    }
    let mut failed = false;
    if let Some(w) = o.assert_layers
        && c.mapped_layers().len() != w
    {
        err(&format!("FAIL: expected {w} mapped layer surface(s), got {}", c.mapped_layers().len()));
        failed = true;
    }
    let usable = format!("{},{},{}x{}", u.x, u.y, u.width, u.height);
    if let Some(w) = &o.assert_usable
        && usable != *w
    {
        err(&format!("FAIL: usable area is {usable}, expected {w} — an exclusive zone was not honoured"));
        failed = true;
    }
    if let Some(w) = o.assert_windows
        && windows != w
    {
        err(&format!("FAIL: expected {w} mapped window(s), got {windows}"));
        failed = true;
    }
    if let Some(w) = o.assert_surfaces
        && c.surfaces_created.get() < w
    {
        err(&format!("FAIL: only {} client surfaces were created, expected at least {w} — the load never arrived, so a passing frame count would prove nothing", c.surfaces_created.get()));
        failed = true;
    }
    // C6 (P13.2): every output's island switches together.
    let mut frames: Vec<usize> = conductor.metronomes.iter().flat_map(|m| (0..m.c6.retained()).map(|i| m.c6.sample(i).0)).collect();
    frames.sort_unstable();
    let n = frames.len();
    let pct = |p: usize| if n == 0 { 0 } else { frames[((p * n).div_ceil(100)).clamp(1, n) - 1] };
    out(&format!("c6 switches={n} frames p50={} p99={} max={}", pct(50), pct(99), frames.last().copied().unwrap_or(0)));
    if let Some(w) = o.assert_c6_switches
        && n < w
    {
        err(&format!("FAIL C6: only {n} island switch(es) measured, expected at least {w} — the switches never arrived, so a passing number would prove nothing"));
        failed = true;
    }
    if let Some(l) = o.assert_c6_frames
        && pct(99) > l
    {
        err(&format!("FAIL C6: an island switch took {} frames at p99 (max {}), limit {l} — input to the vblank that showed it", pct(99), frames.last().copied().unwrap_or(0)));
        failed = true;
    }
    if let Some(l) = o.assert_missed
        && rec.missed_count() > l
    {
        err(&format!("FAIL C2: {} missed flips of {}, limit {l} — a client made the compositor drop a frame", rec.missed_count(), rec.retained()));
        failed = true;
    }
    if failed {
        exit(1)
    }
    out("verdict ok");
}

/// One CSV line per frame kept, µs from the first latch (PHASE4 §5.12).
fn write_trace(r: &FlightRecorder, path: &str) {
    use std::io::Write;
    let Ok(mut f) = std::fs::File::create(path) else { return out(&format!("trace: cannot write {path}")) };
    let _ = writeln!(f, "seq,latch,composite_end,submit,predicted_vblank,flip_vblank,margin,cost,wake_late,missed");
    if r.retained() == 0 {
        return;
    }
    let t0 = r.retained_record(0).latch;
    let rel = |t: u64| if t == 0 { String::new() } else { ((t.wrapping_sub(t0) as i64) / 1000).to_string() };
    for i in 0..r.retained() {
        let x = r.retained_record(i);
        let _ = writeln!(f, "{},{},{},{},{},{},{},{},{},{}", x.seq, rel(x.latch), rel(x.composite_end), rel(x.submit), rel(x.predicted_vblank), rel(x.actual_vblank), x.margin_ns / 1000, x.cost_ns / 1000, x.wake_late_ns / 1000, x.missed as u8);
    }
    out(&format!("trace: {} frames to {path}", r.retained()));
}
