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
                      "wlr-screencopy-unstable-v1-protocol.c",
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
        // D-Bus, spoken natively: the wire format, authentication and dispatch,
        // with no libdbus (discouraged upstream), no GDBus (that means GLib and
        // through it the GTK stack this project rejects) and no sd-bus
        // (systemd). PHASE8.md §4.1. Depends on CPlatform only for the
        // SCM_RIGHTS helpers CurrentIPC already uses.
        .target(
            name: "DBus",
            dependencies: ["CPlatform"],
            path: "de/dbus"
        ),
        // The bridge itself: org.freedesktop.portal.FileChooser, translated to
        // `abyss-portal` over CurrentIPC. A library so the path derivation, the
        // options parsing and the URI encoding are unit-tested without a bus.
        .target(
            name: "DBusPortal",
            dependencies: ["DBus", "CurrentIPC"],
            path: "de/dbusportal"
        ),
        // The Aqua toolkit: drawing, theme tokens, the 10.2 widget set.
        .target(
            name: "Aqua",
            dependencies: ["Surface", "CCairo", "CText", "PoolConfig", "CPlatform",
                           "Vents", "CurrentIPC"],
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
        // The installer's thinking half (Phase 5): what an install IS, as a
        // value — the plan, the machine it would run on, the refusals, and the
        // step list it compiles to. Depends on nothing, deliberately: it must be
        // testable on Linux, where not one of the commands it names exists.
        .target(
            name: "Install",
            path: "de/install"
        ),
        // The installer's doing half: running a step list, looking at the
        // machine, and the service `abyss-install` hosts. Separate from
        // `Install` so that target keeps the property that earns it its tests —
        // it imports nothing, so every refusal runs on Linux.
        .target(
            name: "InstallRun",
            dependencies: ["Install", "CurrentIPC", "CPlatform"],
            path: "de/installrun"
        ),
        // The privileged half: runs as root, commanded by an unprivileged GUI,
        // and the only program here whose job is to destroy data.
        .executableTarget(
            name: "abyss-install",
            dependencies: ["Install", "InstallRun", "CurrentIPC"],
            path: "de/installbin"
        ),
        // ...and a caller for it, because an installer that only a graphical
        // program can drive cannot be debugged on a machine with no graphics.
        .executableTarget(
            name: "abyss-installctl",
            dependencies: ["Install", "InstallRun", "CurrentIPC"],
            path: "de/installctl"
        ),
        // The supervisor itself: the Swift replacement for abyss/session.sh.
        .executableTarget(
            name: "anchor",
            dependencies: ["Anchor", "CurrentIPC", "CPlatform"],
            path: "de/anchorbin"
        ),
        // Capsicum: entering capability mode, so the sandboxed client can prove
        // it has no filesystem. Its own target so the toolkit never links it.
        .target(
            name: "CCapsicum",
            path: "de/ccap",
            sources: ["ccap.c"],
            publicHeadersPath: "include"
        ),
        // Capture an output to a PNG, via wlr-screencopy. The screenshot
        // portal's capture step as a separate process, so `abyss-portal` stays
        // a headless service that links neither Wayland nor cairo.
        .executableTarget(
            name: "abyssgrab",
            dependencies: ["Surface", "CCairo"],
            path: "de/abyssgrab"
        ),
        // notify-send, brokerless: through the portal, as a jailed app would.
        .executableTarget(
            name: "abyssnotify",
            dependencies: ["CurrentIPC"],
            path: "de/abyssnotify"
        ),
        // The point of the portal, demonstrated: no filesystem, yet it reads
        // the file the user picked.
        .executableTarget(
            name: "abyssopen",
            dependencies: ["CurrentIPC", "CCapsicum"],
            path: "de/abyssopen"
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
        // Count heap allocations on the calling thread, by symbol interposition.
        // The enforcement half of PLAN.md's risk 4: the present path's
        // allocation-freedom is a test that runs every build, not a number
        // somebody once measured. Only works in an executable — see the header.
        .target(
            name: "CAllocProbe",
            path: "de/callocprobe",
            sources: ["callocprobe.c"],
            publicHeadersPath: "include"
        ),
        // wlroots + libwayland-server, reached the portable way: only a
        // systemLibrary can carry `pkgConfig:`, and dependents inherit its
        // cflags/libs (HANDOFF §2.29). wlroots is PINNED to 0.19 — the guest
        // offers 0.20 as well and a compositor built against different wlroots
        // per platform is a failure mode we have not had (PHASE6.md §7.3).
        .systemLibrary(
            name: "CWlrootsSys",
            path: "de/cwlrootssys",
            pkgConfig: "wlroots-0.19",
            providers: [.apt(["libwlroots-dev"])]
        ),
        .systemLibrary(
            name: "CWaylandServer",
            path: "de/cwaylandserver",
            pkgConfig: "wayland-server",
            providers: [.apt(["libwayland-dev"])]
        ),
        // The C floor under the compositor — and it is nearly empty, because
        // Swift imports wlroots directly. What needs C is libwayland's event
        // model: `wl_signal_add` is a static inline and `wl_container_of` is a
        // macro, so every wlroots event arrives through one C trampoline.
        .target(
            name: "CWlroots",
            dependencies: ["CWlrootsSys", "CWaylandServer"],
            path: "de/cwlroots",
            sources: ["cwlroots.c"],
            publicHeadersPath: "include"
        ),
        // `undertow` — the compositor (PHASE6.md). P6.1 is the frame scheduler
        // and the flight recorder that makes the C1-C5 contract falsifiable;
        // P6.2 puts real wlroots frames under it.
        .target(
            name: "Undertow",
            dependencies: ["CWlroots", "PoolConfig"],
            path: "de/undertow"
        ),
        .executableTarget(
            name: "undertow",
            dependencies: ["Undertow", "CAllocProbe"],
            path: "de/undertowbin"
        ),
        // Drive the DBus library against a real bus — the client on the other
        // end is dbus-send, not us (PHASE8.md §5).
        .executableTarget(
            name: "dbusprobe",
            dependencies: ["DBus"],
            path: "de/dbusprobe"
        ),
        // `org.freedesktop.portal.Desktop`, hosted by us: the legacy adapter
        // that gets a stock GTK or Qt app the Finder as its file chooser.
        .executableTarget(
            name: "abyss-dbus",
            dependencies: ["DBusPortal", "CurrentIPC"],
            path: "de/dbusbin"
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
        .testTarget(
            name: "InstallTests",
            dependencies: ["Install"],
            path: "Tests/InstallTests"
        ),
        .testTarget(
            name: "InstallRunTests",
            dependencies: ["InstallRun", "Install", "CurrentIPC"],
            path: "Tests/InstallRunTests"
        ),
        .testTarget(
            name: "DBusTests",
            dependencies: ["DBus"],
            path: "Tests/DBusTests"
        ),
        .testTarget(
            name: "DBusPortalTests",
            // `Aqua` is here for one assertion: the accent colour the Settings
            // portal publishes is a literal, and this is what stops it drifting
            // away from the theme token it was copied from.
            dependencies: ["DBusPortal", "DBus", "CurrentIPC", "Aqua"],
            path: "Tests/DBusPortalTests"
        ),
        .testTarget(
            name: "UndertowTests",
            dependencies: ["Undertow"],
            path: "Tests/UndertowTests"
        ),
    ]
)
