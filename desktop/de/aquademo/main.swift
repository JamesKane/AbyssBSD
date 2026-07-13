// AquaDemo — brings up a faithful Jaguar window under any wlroots compositor
// (sway/labwc on Linux today; tide on FreeBSD later).
//
//   WAYLAND_DISPLAY must point at a running compositor.
//   AQUA_SCENE=sysprefs  picks the System Preferences demo (else a simple window).
//   AQUA_SCALE=2         forces 2x rendering to check HiDPI crispness.
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

let sysPrefs = envString("AQUA_SCENE") == "sysprefs"
let scene: SceneKind = sysPrefs ? .systemPreferences : .window
let title = sysPrefs ? "System Preferences" : "AbyssBSD"
let width: Int32 = sysPrefs ? 760 : 440
let height: Int32 = sysPrefs ? 620 : 300

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

// The caller owns the window: Display.window and Window.delegate are both weak
// (to avoid a retain cycle), so this strong reference is the only thing keeping
// the window — and its Wayland listeners' data pointers — alive. Discarding it
// (e.g. `guard let _ =`) frees the window before the first configure event and
// crashes in the listener callback. withExtendedLifetime pins it across run().
guard let window = AquaWindow(display: display, title: title, scene: scene,
                              width: width, height: height) else {
    print("AquaDemo: failed to create the window.")
    exit(1)
}

print("AquaDemo: window is up. Close it to quit.")
withExtendedLifetime(window) {
    display.run()
}
