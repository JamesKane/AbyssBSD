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
        // Config: read/write the same ~/.config/abyss/*.ini files as the Rust
        // `pool` (mmap read, atomic-rename write, directory watch). Pure syscalls;
        // no Wayland, so the shell components and tests use it independently.
        .target(
            name: "PoolConfig",
            dependencies: ["CPoolWatch"],
            path: "de/poolconfig"
        ),
        // The Aqua toolkit: drawing, theme tokens, the 10.2 widget set.
        .target(
            name: "Aqua",
            dependencies: ["Surface", "CCairo", "CText", "PoolConfig"],
            path: "de/aqua"
        ),
        // Demo: a single faithful Aqua window with live controls.
        .executableTarget(
            name: "AquaDemo",
            dependencies: ["Aqua"],
            path: "de/aquademo"
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
    ]
)
