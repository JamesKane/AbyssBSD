// swift-tools-version: 6.0
//
// AbyssBSD — Swift 6 desktop environment (Mac OS X 10.2 "Jaguar" Aqua on Wayland).
//
// Layout note: Swift/C targets live under de/ to mirror the sibling AbyssBSD
// tree. The sibling's Rust components are a design source to rewrite from, not
// dependencies — the engine gets written in Swift here too (docs/PLAN.md).
import PackageDescription

let package = Package(
    name: "AbyssBSD",
    products: [
        .library(name: "Aqua", targets: ["Aqua"]),
        .library(name: "Surface", targets: ["Surface"]),
        .library(name: "PoolConfig", targets: ["PoolConfig"]),
        .library(name: "CurrentIPC", targets: ["CurrentIPC"]),
        .library(name: "Vents", targets: ["Vents"]),
        .library(name: "Portal", targets: ["Portal"]),
        .executable(name: "AquaDemo", targets: ["AquaDemo"]),
    ],
    targets: [
        // libwayland-client itself, via pkg-config. CWayland is a plain C
        // target and so cannot carry a `pkgConfig:` of its own; depending on
        // this systemLibrary is how it inherits the include dir and the
        // -lwayland-client flag. Needed on FreeBSD, where the headers are under
        // /usr/local/include — the previous `.linkedLibrary("wayland-client")`
        // silently relied on Linux putting them in /usr/include.
        .systemLibrary(
            name: "CWaylandClient",
            path: "de/cwaylandclient",
            pkgConfig: "wayland-client",
            providers: [.apt(["libwayland-dev"]), .brew(["wayland"])]
        ),
        // C interop: generated protocol clients + the aw_* shim + shm helper.
        .target(
            name: "CWayland",
            dependencies: ["CWaylandClient"],
            path: "de/cwayland",
            exclude: ["generate-protocols.sh"],
            sources: ["xdg-shell-protocol.c",
                      "wlr-layer-shell-unstable-v1-protocol.c",
                      "wlr-foreign-toplevel-management-unstable-v1-protocol.c",
                      "xdg-activation-v1-protocol.c",
                      "cwayland_shm.c", "cwayland_shim.c"],
            publicHeadersPath: "include"
        ),
        // System cairo (software 2D backend for the Aqua toolkit; cairo-ft
        // bridges the shaped glyphs from CText into cairo_show_glyphs).
        .systemLibrary(
            name: "CCairo",
            path: "de/ccairo",
            pkgConfig: "cairo",
            providers: [
                .apt(["libcairo2-dev"]),
                .brew(["cairo"]),
            ]
        ),
        // FreeType + HarfBuzz, reached via pkg-config so the include dirs and
        // link flags stay portable (Fedora/Debian now, FreeBSD later) rather
        // than hard-coded. CText compiles against these; nothing imports them
        // from Swift directly.
        .systemLibrary(
            name: "CFreeType",
            path: "de/cfreetype",
            pkgConfig: "freetype2",
            providers: [.apt(["libfreetype-dev"]), .brew(["freetype"])]
        ),
        .systemLibrary(
            name: "CHarfBuzz",
            path: "de/charfbuzz",
            pkgConfig: "harfbuzz",
            providers: [.apt(["libharfbuzz-dev"]), .brew(["harfbuzz"])]
        ),
        // xkbcommon: turns raw evdev keycodes from wl_keyboard into keysyms +
        // UTF-8, honouring the compositor's keymap. Imported from Surface.
        .systemLibrary(
            name: "CXkb",
            path: "de/cxkb",
            pkgConfig: "xkbcommon",
            providers: [.apt(["libxkbcommon-dev"]), .brew(["libxkbcommon"])]
        ),
        // Real text: FreeType face management + HarfBuzz shaping behind a small
        // C API (the FT header macros and hb buffer lifecycle are awkward from
        // Swift; Aqua paints the shaped run via cairo-ft).
        .target(
            name: "CText",
            dependencies: ["CFreeType", "CHarfBuzz"],
            path: "de/ctext",
            sources: ["ctext.c"],
            publicHeadersPath: "include"
        ),
        // Wayland client runtime: connection, registry, surfaces, shm, input.
        .target(
            name: "Surface",
            dependencies: ["CWayland", "CXkb"],
            path: "de/surface"
        ),
        // Portable "config directory changed" watch (inotify/kqueue) for
        // PoolConfig — the one platform-specific piece, isolated in C.
        .target(
            name: "CPoolWatch",
            path: "de/cpoolwatch",
            sources: ["cpoolwatch.c"],
            publicHeadersPath: "include"
        ),
        // Platform facts Swift can't reach: Swift's libc module surfaces no
        // <sys/sysctl.h>, so "what is my own executable?" needs C on FreeBSD
        // (/proc/self/exe on Linux, KERN_PROC_PATHNAME there).
        .target(
            name: "CPlatform",
            path: "de/cplatform",
            sources: ["cplatform.c"],
            publicHeadersPath: "include"
        ),
        // Config: read/write the same ~/.config/abyss/*.ini files as the Rust
        // `pool` (mmap read, atomic-rename write, directory watch). Pure syscalls;
        // no Wayland, so the shell components and tests use it independently.
        .target(
            name: "PoolConfig",
            dependencies: ["CPoolWatch"],
            path: "de/poolconfig"
        ),
        // The control plane: brokerless unix-socket IPC with typed messages and
        // SCM_RIGHTS fd passing (a Swift rewrite of the sibling's `current`).
        // No Wayland and no Aqua — the supervisor and the hardware bridges use
        // it independently of the shell.
        .target(
            name: "CurrentIPC",
            dependencies: ["CPlatform"],
            path: "de/currentipc"
        ),
        // The Aqua toolkit: drawing, theme tokens, the 10.2 widget set.
        .target(
            name: "Aqua",
            dependencies: ["Surface", "CCairo", "CText", "PoolConfig", "CPlatform", "Vents"],
            path: "de/aqua"
        ),
        // Demo: a single faithful Aqua window with live controls.
        .executableTarget(
            name: "AquaDemo",
            dependencies: ["Aqua"],
            path: "de/aquademo"
        ),
        // Two-process control-plane probe: hands a real descriptor from one
        // process to another (abyss/tests/live-ipc.sh drives it).
        .executableTarget(
            name: "ipcprobe",
            dependencies: ["CurrentIPC"],
            path: "de/ipcprobe"
        ),
        // The C floor under the FreeBSD hardware bridges: sysctlbyname (Swift's
        // libc module surfaces no <sys/sysctl.h>) and the OSS mixer ioctls
        // (ioctl is variadic, which Swift cannot call). Stubs elsewhere.
        .target(
            name: "CVents",
            path: "de/cvents",
            sources: ["cvents.c"],
            publicHeadersPath: "include"
        ),
        // The hardware bridges themselves: sysctl, volume, battery, devd.
        // The shell reads the machine through native facilities — sysctl not
        // sysfs, OSS not ALSA, devd not udev.
        .target(
            name: "Vents",
            dependencies: ["CVents"],
            path: "de/vents"
        ),
        // Process supervision primitives: every child is a pollable descriptor
        // (pdfork on FreeBSD, pidfd on Linux) plus a signal self-pipe.
        .target(
            name: "CProc",
            path: "de/cproc",
            sources: ["cproc.c"],
            publicHeadersPath: "include"
        ),
        // The session supervisor's logic — restart policy, the poll loop, the
        // control service. A library so it can be tested without a session.
        .target(
            name: "Anchor",
            dependencies: ["CProc", "CurrentIPC"],
            path: "de/anchor"
        ),
        // The supervisor itself: the Swift replacement for abyss/session.sh.
        .executableTarget(
            name: "anchor",
            dependencies: ["Anchor", "CurrentIPC", "CPlatform"],
            path: "de/anchorbin"
        ),
        // The desktop's portal: the picker runs, the portal opens what the user
        // chose, and the descriptor goes back over SCM_RIGHTS. No D-Bus.
        .target(
            name: "Portal",
            dependencies: ["CurrentIPC", "CProc", "CPlatform"],
            path: "de/portal"
        ),
        .executableTarget(
            name: "abyss-portal",
            dependencies: ["Portal", "CurrentIPC"],
            path: "de/portalbin"
        ),
        // Read the machine through the FreeBSD-native bridges.
        .executableTarget(
            name: "ventsctl",
            dependencies: ["Vents"],
            path: "de/ventsctl"
        ),
        // Drive a running session over the control plane.
        .executableTarget(
            name: "abyssctl",
            dependencies: ["CurrentIPC"],
            path: "de/abyssctl"
        ),
        .testTarget(
            name: "AquaTests",
            dependencies: ["Aqua", "PoolConfig"],
            path: "Tests/AquaTests"
        ),
        .testTarget(
            name: "PoolConfigTests",
            dependencies: ["PoolConfig"],
            path: "Tests/PoolConfigTests"
        ),
        .testTarget(
            name: "CurrentIPCTests",
            dependencies: ["CurrentIPC"],
            path: "Tests/CurrentIPCTests"
        ),
        .testTarget(
            name: "PortalTests",
            dependencies: ["Portal", "CurrentIPC"],
            path: "Tests/PortalTests"
        ),
        .testTarget(
            name: "VentsTests",
            dependencies: ["Vents"],
            path: "Tests/VentsTests"
        ),
        .testTarget(
            name: "AnchorTests",
            dependencies: ["Anchor"],
            path: "Tests/AnchorTests"
        ),
    ]
)
