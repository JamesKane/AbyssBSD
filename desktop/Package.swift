// swift-tools-version: 6.0
//
// AbyssBSD — Swift 6 desktop environment (Mac OS X 10.2 "Jaguar" Aqua on Wayland).
//
// Layout note: Swift/C targets live under de/ to mirror the sibling AbyssBSD
// tree. Borrowed Rust engine components (tide, current, pool, …) will be added
// under de/ as well in Phase 3 and are built outside SwiftPM.
import PackageDescription

let package = Package(
    name: "AbyssBSD",
    products: [
        .library(name: "Aqua", targets: ["Aqua"]),
        .library(name: "Surface", targets: ["Surface"]),
        .executable(name: "AquaDemo", targets: ["AquaDemo"]),
    ],
    targets: [
        // C interop: libwayland-client + generated xdg-shell + shm helper.
        .target(
            name: "CWayland",
            path: "de/cwayland",
            exclude: ["generate-protocols.sh"],
            sources: ["xdg-shell-protocol.c", "cwayland_shm.c", "cwayland_shim.c"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("wayland-client")]
        ),
        // System cairo (software 2D backend for the Aqua toolkit).
        .systemLibrary(
            name: "CCairo",
            path: "de/ccairo",
            pkgConfig: "cairo",
            providers: [
                .apt(["libcairo2-dev"]),
                .brew(["cairo"]),
            ]
        ),
        // Wayland client runtime: connection, registry, surfaces, shm, input.
        .target(
            name: "Surface",
            dependencies: ["CWayland"],
            path: "de/surface"
        ),
        // The Aqua toolkit: drawing, theme tokens, the 10.2 widget set.
        .target(
            name: "Aqua",
            dependencies: ["Surface", "CCairo"],
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
            dependencies: ["Aqua"],
            path: "Tests/AquaTests"
        ),
    ]
)
