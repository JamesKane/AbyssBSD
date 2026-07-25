// AquaDemo — brings up a faithful Jaguar window under any wlroots compositor
// (sway/labwc on Linux today; tide on FreeBSD later).
//
//   WAYLAND_DISPLAY must point at a running compositor.
//   AQUA_SCENE=sysprefs  picks the System Preferences demo (else a simple window).
//   AQUA_SCALE=2         pins 2x rendering (overrides the automatic per-output
//                        scale, which the window otherwise tracks from wl_output).
//   AQUA_RENDER_PNG=path renders one frame to PNG and exits (no compositor).

import Surface
import Aqua

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func envString(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}

let sceneName = envString("AQUA_SCENE")
let scene: SceneKind
let title: String
let width: Int32
let height: Int32
switch sceneName {
case "sysprefs":
    scene = .systemPreferences; title = "System Preferences"; width = 760; height = 620
case "widgets":
    scene = .widgets; title = "Aqua Controls"; width = 460; height = 360
case "scroll":
    scene = .scroll; title = "Scroll"; width = 360; height = 420
case "tabs":
    scene = .tabs; title = "Tab View"; width = 480; height = 380
case "sheet":
    scene = .sheet; title = "Sheets"; width = 440; height = 320
case "wallpaper":
    // A wlr-layer-shell BACKGROUND client. PNG preview uses a fixed size; live,
    // the compositor stretches it to the output.
    scene = .wallpaper; title = "Desktop"; width = 800; height = 600
case "menubar":
    // A wlr-layer-shell TOP client. PNG preview composites the bar over the
    // wallpaper at this size; live, it spans the output width at bar height.
    scene = .menubar; title = "Menu Bar"; width = 800; height = 600
case "dock":
    // A wlr-layer-shell BOTTOM client (the magnifying Dock).
    scene = .dock; title = "Dock"; width = 800; height = 600
case "finder":
    // The file browser — an ordinary xdg-shell toplevel, not a shell surface.
    // Starts in $ABYSS_FINDER_DIR (else $HOME).
    scene = .finder; title = "Finder"; width = 520; height = 400
default:
    scene = .window; title = "AbyssBSD"; width = 440; height = 300
}

if let out = envString("AQUA_RENDER_PNG") {
    let scale = Int32(envString("AQUA_SCALE") ?? "") ?? 1
    let ok = renderScenePNG(path: out, kind: scene, width: width, height: height,
                            scale: max(1, scale), title: title, clickCount: 3)
    print(ok ? "AquaDemo: wrote \(out)" : "AquaDemo: PNG render failed")
    exit(ok ? 0 : 1)
}

guard let display = Display() else {
    print("AquaDemo: cannot connect to a Wayland compositor " +
          "(is WAYLAND_DISPLAY set, and does it offer xdg-shell?).")
    exit(1)
}

// The caller owns the primary surface: Display's back-reference and the
// delegate link are both weak (to avoid a retain cycle), so this strong
// reference is the only thing keeping the surface — and its Wayland listeners'
// data pointers — alive. Discarding it (e.g. `guard let _ =`) frees the surface
// before the first configure event and crashes in the listener callback.
// withExtendedLifetime pins it across run().
if scene == .wallpaper {
    guard let wallpaper = Wallpaper(display: display) else {
        print("AquaDemo: failed to create the wallpaper " +
              "(does the compositor offer wlr-layer-shell?).")
        exit(1)
    }
    print("AquaDemo: wallpaper (layer-shell BACKGROUND) is up.")
    withExtendedLifetime(wallpaper) { display.run() }
} else if scene == .menubar {
    guard let menubar = MenuBar(display: display) else {
        print("AquaDemo: failed to create the menu bar " +
              "(does the compositor offer wlr-layer-shell?).")
        exit(1)
    }
    print("AquaDemo: menu bar (layer-shell TOP) is up.")
    withExtendedLifetime(menubar) { display.run() }
} else if scene == .dock {
    guard let dock = Dock(display: display) else {
        print("AquaDemo: failed to create the Dock " +
              "(does the compositor offer wlr-layer-shell?).")
        exit(1)
    }
    print("AquaDemo: Dock (layer-shell BOTTOM) is up.")
    withExtendedLifetime(dock) { display.run() }
} else if scene == .finder {
    // FinderApp owns the windows (spatial mode opens one per folder); this
    // strong reference is what keeps them — and their listeners — alive.
    let finder = FinderApp(display: display, width: width, height: height)
    guard finder.openInitialWindow() else {
        print("AquaDemo: failed to create the Finder window.")
        exit(1)
    }
    print("AquaDemo: Finder is up (\(FinderWindow.startDirectory()), " +
          "\(finder.toolbarVisible ? "browser" : "spatial") mode).")
    withExtendedLifetime(finder) { display.run() }
} else {
    guard let window = AquaWindow(display: display, title: title, scene: scene,
                                  width: width, height: height) else {
        print("AquaDemo: failed to create the window.")
        exit(1)
    }
    print("AquaDemo: window is up. Close it to quit.")
    withExtendedLifetime(window) { display.run() }
}
