// swift-tools-version: 6.0
//
// AbyssBSD — Swift 6 desktop environment (Mac OS X 10.2 "Jaguar" Aqua on Wayland).
//
// Layout note: Swift/C targets live under de/ to mirror the sibling AbyssBSD
// tree. The sibling's Rust components are a design source to rewrite from, not
// dependencies — the engine gets written in Swift here too (docs/PLAN.md).
import PackageDescription

// /dev/sndstat's nvlist and the mixer library (P14.6): base libraries on
// FreeBSD, absent on Linux, where CVents' sound half is stubs. This
// PackageDescription has no `.freebsd` platform condition, and the manifest is
// compiled on the machine it builds for, so the host decides.
#if os(FreeBSD)
let soundLibraries: [LinkerSetting] = [.linkedLibrary("nv"), .linkedLibrary("mixer")]
#else
let soundLibraries: [LinkerSetting] = []
#endif

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
        // The interface tables of protocols this project defines, compiled once
        // for both halves (see its header, and PHASE10.md P10.3).
        .target(
            name: "CAbyssProtocols",
            dependencies: ["CWaylandClient"],
            path: "de/cabyssprotocols",
            sources: ["abyss-menu-v1-protocol.c", "abyss-window-v1-protocol.c", "xdg-shell-protocol.c", "gtk-shell-protocol.c",
                      "kde-appmenu-protocol.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CWayland",
            dependencies: ["CWaylandClient", "CAbyssProtocols"],
            path: "de/cwayland",
            exclude: ["generate-protocols.sh"],
            sources: [
                      "wlr-layer-shell-unstable-v1-protocol.c",
                      "wlr-foreign-toplevel-management-unstable-v1-protocol.c",
                      "xdg-activation-v1-protocol.c",
                      "wlr-screencopy-unstable-v1-protocol.c",
                      "wlr-output-management-unstable-v1-protocol.c",
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
        // Font families by name (P11.7): a theme names a family per role, and
        // fontconfig finds its files — the vendored fonts/ included.
        .systemLibrary(
            name: "CFontconfig",
            path: "de/cfontconfig",
            pkgConfig: "fontconfig",
            providers: [.apt(["libfontconfig-dev"]), .brew(["fontconfig"])]
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
            dependencies: ["CFreeType", "CHarfBuzz", "CFontconfig"],
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
            publicHeadersPath: "include",
            // crypt(3) needs -lcrypt on both platforms — the installer hashes a
            // password in the GUI so no plaintext crosses the control plane.
            linkerSettings: [.linkedLibrary("crypt")]
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
            dependencies: ["DBus", "CurrentIPC", "PoolConfig"],
            path: "de/dbusportal"
        ),
        // GTK's menus as our vocabulary: org.gtk.Menus/Actions read over the
        // bus and served as MenuWire (PHASE10.md P10.6).
        .target(
            name: "DBusMenus",
            dependencies: ["DBus", "CurrentIPC", "MenuModel", "MenuWire"],
            path: "de/dbusmenus"
        ),
        // The drawing grammar — Rect, Theme, Draw, Text and the window chrome
        // they compose into. Its own target because **the compositor links it
        // too** (P9.6): server-side decorations mean undertow paints an Aqua
        // title bar, and the alternative was writing Aqua twice and keeping two
        // of them in step (PHASE9 §6.1). Nothing here has ever depended on
        // `Surface`, which is what made it separable.
        // The draw-list interpreter's two pixel loops: blur and noise (P11.3).
        .target(
            name: "CDraw",
            path: "de/cdraw",
            sources: ["cdraw.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "AquaDraw",
            dependencies: ["CCairo", "CText", "CDraw", "PoolConfig"],
            path: "de/aquadraw"
        ),
        // What an application can do, as a value: commands, key equivalents,
        // menus (PHASE10.md P10.1). Depends on nothing, so the menu wire and a
        // command-line client can link it without linking an application.
        .target(
            name: "MenuModel",
            path: "de/menumodel"
        ),
        // An application's vocabulary on the control plane: describe, validate,
        // activate, subscribe (PHASE10.md P10.2). No toolkit, so `abyssmenu`
        // and the menu bar link it without linking an application.
        .target(
            name: "MenuWire",
            dependencies: ["MenuModel", "CurrentIPC"],
            path: "de/menuwire"
        ),
        // SVG artwork into draw lists, at build time (PHASE11 P11.8) — so no
        // process on the desktop parses SVG. A library for the tests, and a tool.
        .target(
            name: "SVGImport",
            path: "de/svgimport"
        ),
        // The loaded theme for things that do not draw: the portal's palette,
        // and a theme author's legibility check (PHASE11 P11.10).
        .executableTarget(
            name: "abyss-theme",
            dependencies: ["AquaDraw"],
            path: "de/abysstheme"
        ),
        .executableTarget(
            name: "svg2dl",
            dependencies: ["SVGImport"],
            path: "de/svg2dl"
        ),
        // Ask an application what it can do, and have it do it.
        .executableTarget(
            name: "abyssmenu",
            dependencies: ["MenuWire", "MenuModel", "CurrentIPC"],
            path: "de/abyssmenu"
        ),
        // The Aqua toolkit: drawing, theme tokens, the 10.2 widget set.
        .target(
            name: "Aqua",
            dependencies: ["AquaDraw", "MenuModel", "MenuWire", "Surface", "CCairo", "CText", "PoolConfig", "CPlatform", "Spawn",
                           "Vents", "CurrentIPC",
                           // The installer's model builds an InstallPlan and
                           // asks the same refusals P5.1 wrote whether a disk
                           // may be chosen. `Install` depends on nothing, so
                           // this costs the toolkit no new libraries.
                           "Install", "InstallWire",
                           // The Network pane speaks the settings helper's
                           // protocol (P14.4c) — and, like the installer, does
                           // not link the half that runs `sysrc`.
                           "Settings", "SettingsWire"],
            path: "de/aqua"
        ),
        // Demo: a single faithful Aqua window with live controls.
        .executableTarget(
            name: "AquaDemo",
            // AquaDraw directly, not only through Aqua's re-export: SwiftPM
            // recompiles across a layout change in a type (ThemeTokens grows
            // through Phase 11) only along a declared dependency, and a stale
            // object destroying the old layout crashed at exit (PHASE11 P11.2).
            dependencies: ["Aqua", "AquaDraw"],
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
            publicHeadersPath: "include",
            linkerSettings: soundLibraries
        ),
        // The hardware bridges themselves: sysctl, volume, battery, devd.
        // The shell reads the machine through native facilities — sysctl not
        // sysfs, OSS not ALSA, devd not udev.
        .target(
            name: "Vents",
            dependencies: ["CVents", "Spawn"],
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
        // Starting a program detached, async-signal-safely: resolve and
        // allocate in the parent, only fork/setsid/execve/_exit in the child
        // (BACKLOG S.2). No dependencies, so the compositor and the supervisor
        // can share it without the toolkit.
        .target(name: "Spawn", path: "de/spawn"),
        // System Preferences' privileged half (PHASE14 P14.3), in the
        // installer's shape: plans as values that import nothing, a wire the
        // pane links without the executor, the runner, and two binaries.
        .target(name: "Settings", path: "de/settings"),
        .target(name: "SettingsWire", dependencies: ["Settings", "CurrentIPC"], path: "de/settingswire"),
        .target(name: "SettingsRun",
                dependencies: ["Settings", "SettingsWire", "CurrentIPC", "CPlatform", "Spawn"],
                path: "de/settingsrun"),
        .executableTarget(name: "abyss-settings",
                          dependencies: ["SettingsRun", "CurrentIPC"], path: "de/settingsbin"),
        .executableTarget(name: "abyss-settingsctl",
                          dependencies: ["Settings", "SettingsWire", "CurrentIPC"], path: "de/settingsctl"),
        .target(
            name: "Anchor",
            dependencies: ["CProc", "CurrentIPC", "Spawn"],
            path: "de/anchor"
        ),
        // The installer's thinking half (Phase 5): what an install IS, as a
        // value — the plan, the machine it would run on, the refusals, and the
        // step list it compiles to. Depends on nothing, deliberately: it must be
        // testable on Linux, where not one of the commands it names exists.
        .target(
            name: "Install",
            // `Fathom` so the machine-quirk rules have exactly one definition:
            // whether a machine needs a workaround is a fact *about the
            // machine*, and the installer is one consumer of it rather than its
            // owner. Both targets are dependency-free, so `Install` keeps the
            // property that earns it its tests — every refusal still checks on
            // Linux, where `gpart` does not exist.
            dependencies: ["Fathom"],
            path: "de/install"
        ),
        // What this machine is, as a value (PHASE12.md). Pure functions over
        // captured text and **no dependencies at all** — the same property that
        // earns `Install` its tests, for the same reason: every probe has to be
        // checkable on a machine that has none of the hardware, which is most of
        // them. The gathering half lives with the caller.
        .target(
            name: "Fathom",
            path: "de/fathom"
        ),
        // The installer's doing half: running a step list, looking at the
        // machine, and the service `abyss-install` hosts. Separate from
        // `Install` so that target keeps the property that earns it its tests —
        // it imports nothing, so every refusal runs on Linux.
        // The install protocol on the control plane. Its own target so the GUI
        // can speak it without linking the half that forks `gpart`.
        .target(
            name: "InstallWire",
            dependencies: ["Install", "CurrentIPC"],
            path: "de/installwire"
        ),
        .target(
            name: "InstallRun",
            // `Vents` for the kernel environment: the machine's identity is in
            // `kenv`, not sysctl, and this is the half that is allowed to look.
            dependencies: ["Install", "InstallWire", "CurrentIPC", "CPlatform", "Vents", "Spawn"],
            path: "de/installrun"
        ),
        // The privileged half: runs as root, commanded by an unprivileged GUI,
        // and the only program here whose job is to destroy data.
        .executableTarget(
            name: "abyss-install",
            dependencies: ["Install", "InstallRun", "InstallWire", "CurrentIPC"],
            path: "de/installbin"
        ),
        // ...and a caller for it, because an installer that only a graphical
        // program can drive cannot be debugged on a machine with no graphics.
        .executableTarget(
            name: "abyss-installctl",
            dependencies: ["Install", "InstallWire", "CurrentIPC"],
            path: "de/installctl"
        ),
        // The supervisor itself: the Swift replacement for abyss/session.sh.
        .executableTarget(
            name: "anchor",
            dependencies: ["Anchor", "CurrentIPC", "CPlatform", "Spawn"],
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
        // The displays, through wlr-output-management-v1 (PHASE14 P14.7b).
        .executableTarget(
            name: "abyss-displays",
            dependencies: ["Surface"],
            path: "de/displaysctl"
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
            dependencies: ["CurrentIPC", "CProc", "CPlatform", "Spawn"],
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
        // pixman, for pointer-constraint regions (U.6) — see its modulemap.
        .systemLibrary(
            name: "CPixman",
            path: "de/cpixman",
            pkgConfig: "pixman-1",
            providers: [.apt(["libpixman-1-dev"])]
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
            dependencies: ["CWlrootsSys", "CWaylandServer", "CAbyssProtocols"],
            path: "de/cwlroots",
            sources: ["cwlroots.c", "menus.c"],
            publicHeadersPath: "include"
        ),
        // `undertow` — the compositor (PHASE6.md). P6.1 is the frame scheduler
        // and the flight recorder that makes the C1-C5 contract falsifiable;
        // P6.2 puts real wlroots frames under it.
        .target(
            name: "Undertow",
            // CXkb because the keybind table turns a keycode into a keysym
            // (P9.5). wlroots' headers declare xkbcommon's functions, so the
            // *compile* worked without it and only the link failed — the module
            // is here for the library, not for the declarations.
            // AquaDraw + cairo because the compositor paints the window frames
            // now (P9.6): server-side decorations mean an Aqua title bar with
            // gel lights, drawn from the same grammar the toolkit uses.
            // Install for its keymap table: rc.conf's `keymap=` is a kbdmap
            // name and the seat needs an XKB layout (HANDOFF §2.70). `Install`
            // depends on nothing, so this links no new library.
            dependencies: ["CWlroots", "PoolConfig", "CXkb", "AquaDraw", "CCairo", "MenuModel",
                           "Install", "Spawn", "CPixman"],
            path: "de/undertow"
        ),
        .executableTarget(
            name: "undertow",
            dependencies: ["Undertow", "CAllocProbe", "AquaDraw"],
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
            dependencies: ["DBusPortal", "DBusMenus", "CurrentIPC", "Spawn", "PoolConfig"],
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
            dependencies: ["Aqua", "AquaDraw", "PoolConfig", "SVGImport", "CurrentIPC", "Settings", "SettingsWire", "Vents"],
            path: "Tests/AquaTests"
        ),
        .testTarget(
            name: "MenuModelTests",
            dependencies: ["MenuModel", "MenuWire", "CurrentIPC", "DBusMenus", "DBus"],
            path: "Tests/MenuModelTests"
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
        // The half that is allowed to look at the machine. Kept out of `Fathom`
        // so the probes stay pure — the same split as `Install`/`InstallRun`.
        // The clipboard from a shell — a tool, and the vehicle that lets a
        // script prove copy and paste actually cross a process boundary.
        .executableTarget(
            name: "abyssclip",
            dependencies: ["Surface"],
            path: "de/abyssclip"
        ),
        .executableTarget(
            name: "fathom",
            dependencies: ["Fathom", "Vents", "Spawn"],
            path: "de/fathombin"
        ),
        .testTarget(
            name: "FathomTests",
            dependencies: ["Fathom"],
            path: "Tests/FathomTests"
        ),
        .testTarget(
            name: "InstallTests",
            dependencies: ["Install"],
            path: "Tests/InstallTests"
        ),
        .testTarget(
            name: "InstallRunTests",
            dependencies: ["InstallRun", "InstallWire", "Install", "CurrentIPC"],
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
            dependencies: ["DBusPortal", "DBus", "CurrentIPC", "Aqua", "AquaDraw"],
            path: "Tests/DBusPortalTests"
        ),
        .testTarget(
            name: "SettingsTests",
            dependencies: ["Settings", "SettingsWire", "SettingsRun", "CurrentIPC"],
            path: "Tests/SettingsTests"
        ),
        .testTarget(
            name: "SpawnTests",
            dependencies: ["Spawn"],
            path: "Tests/SpawnTests"
        ),
        .testTarget(
            name: "UndertowTests",
            dependencies: ["Undertow", "PoolConfig", "AquaDraw", "Install"],
            path: "Tests/UndertowTests"
        ),
    ]
)
