// swift-tools-version: 6.2

import PackageDescription

// MacBeeb builds on macOS (the Mac app: SwiftUI, AppKit and Metal) and on
// Linux (the same app on GTK 4 and libadwaita, with OpenGL, SDL and
// GStreamer). Everything but the apps' user interfaces is shared, and so is
// most of the app: Sources/MacBeeb/Shared is built into both, with
// Sources/MacBeeb/macOS or Sources/MacBeeb/Linux beside it.
//
// The manifest is evaluated on the machine that builds, so `#if os(Linux)`
// here picks the Linux app and the system libraries it uses; on a Mac the
// targets are as they've always been.

/// What only the Linux build depends on: its system libraries, and LZFSE.
func linux(_ names: String...) -> [Target.Dependency] {
    #if os(Linux)
    return names.map { .target(name: $0, condition: .when(platforms: [.linux])) }
    #else
    return []
    #endif
}

var products: [Product] = [
    .library(name: "BeebCore", targets: ["BeebCore"]),
    .library(name: "BeebCapture", targets: ["BeebCapture"]),
    .library(name: "BeebROMs", targets: ["BeebROMs"]),
    .library(name: "BeebLibrary", targets: ["BeebLibrary"]),
    .executable(name: "beeb", targets: ["beeb"]),
    .executable(name: "MacBeeb", targets: ["MacBeeb"]),
    .executable(name: "macbeeb-mcp", targets: ["macbeeb-mcp"]),
    .executable(name: "beeb-bench", targets: ["beeb-bench"]),
    .library(name: "BeebWasm", targets: ["BeebWasm"]),
    .executable(name: "BeebWasmModule", targets: ["BeebWasmModule"]),
    .executable(name: "m6502-gen", targets: ["m6502-gen"]),
]

var targets: [Target] = [
    // The emulation core: pure Swift, no UI or platform frameworks.
    //
    // Runtime exclusivity checks on class properties cost ~6x in the
    // per-cycle hot loop, so they're off for the core. (Compile-time
    // checks still apply.)
    .target(
        name: "BeebCore",
        dependencies: linux("CLZFSE"),
        swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"])]
    ),

    // The standard ROM images and the co-processors' system discs
    // (Acorn and Digital Research copyright, not GPL).
    .target(name: "BeebROMs", dependencies: ["BeebCore"], resources: [.copy("ROMs"), .copy("Discs"), .copy("Sounds")]),

    // The BBC Micro Classics bookshelf's catalogue and covers, the
    // library of imported games, and quick saves.
    .target(name: "BeebLibrary", dependencies: ["BeebCore"], exclude: ["COVERS.md"],
            resources: [.copy("Covers"), .copy("Data")]),

    // Screenshots and video recording (AVFoundation on the Mac, GStreamer
    // on Linux).
    .target(name: "BeebCapture", dependencies: ["BeebCore"] + linux("CZlib", "CGStreamer")),

    // Runs a machine on its own thread, paced by audio or the wall clock.
    .target(name: "BeebHost", dependencies: ["BeebCore", "BeebCapture", "BeebPrint"]),

    // Printing: jobs as the BBC sent them, laid out on pages, and PDFs
    // (Core Graphics on the Mac, Cairo on Linux).
    .target(name: "BeebPrint", dependencies: linux("CCairo")),

    // Networks of machines: the saved project, templates, and the
    // network that runs them.
    .target(name: "BeebNetwork", dependencies: ["BeebCore", "BeebHost", "BeebROMs", "BeebPrint"]),

    .executableTarget(name: "beeb", dependencies: ["BeebCore", "BeebCapture", "BeebROMs"]),

    // Tools for AI agents to drive a machine, and the MCP server.
    .target(name: "BeebAgentKit", dependencies: ["BeebCore", "BeebHost", "BeebCapture", "BeebROMs"]),
    // The Debug Adapter Protocol server, for VS Code and other editors.
    .target(name: "BeebDAP", dependencies: ["BeebCore", "BeebHost", "BeebROMs", "BeebAgentKit"]),
    .executableTarget(name: "macbeeb-mcp", dependencies: ["BeebAgentKit", "BeebCore", "BeebHost", "BeebROMs"]),

    // 6502 state machine generator. Run `swift run m6502-gen` after
    // changing M6502GenKit; a test checks the output is up to date.
    .target(name: "M6502GenKit"),
    .executableTarget(name: "m6502-gen", dependencies: ["M6502GenKit"]),

    .executableTarget(name: "beeb-bench", dependencies: ["BeebCore", "BeebHost", "BeebROMs"]),

    // WebAssembly: BeebCore behind a flat C ABI (docs/wasm.md), and the
    // module that exports it, a WASI reactor. scripts/build-wasm.sh
    // builds it with the Swift SDK for WebAssembly; natively it's an
    // ordinary library (which the parity tests call) and a stub tool.
    .target(name: "BeebWasm", dependencies: ["BeebCore"]),
    // The discs the browser's Distributed Mandelbrot page boots, built
    // (natively) by the Mac app's own code.
    .executableTarget(name: "web-discs", dependencies: ["BeebCore", "BeebNetwork"]),
    .executableTarget(
        name: "BeebWasmModule",
        dependencies: ["BeebWasm"],
        linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"], .when(platforms: [.wasi]))]
    ),

    .testTarget(
        name: "BeebCoreTests",
        dependencies: ["BeebCore", "BeebROMs", "BeebCapture", "BeebHost", "BeebAgentKit", "BeebDAP", "BeebLibrary",
                       "BeebNetwork", "BeebPrint", "M6502GenKit"] + linux("CZlib"),
        resources: [.copy("Resources")]
    ),

    // perfect6502 (MIT): a transistor-level NMOS 6502 simulation, used
    // only as a test oracle.
    .target(
        name: "Perfect6502",
        path: "Tests/Perfect6502",
        exclude: ["LICENSE", "README.md"],
        cSettings: [.unsafeFlags(["-O2", "-w"])]
    ),
    // The BeebWasm ABI, and parity with the WebAssembly module (whose
    // side is web/tests).
    .testTarget(name: "BeebWasmTests", dependencies: ["BeebWasm"], exclude: ["Fixtures"]),
    .testTarget(
        name: "Oracle6502Tests",
        dependencies: ["BeebCore", "Perfect6502"]
    ),
]

/// What the app is built from on both platforms.
let appDependencies: [Target.Dependency] = ["BeebCore", "BeebHost", "BeebCapture", "BeebROMs", "BeebAgentKit", "BeebDAP",
                                            "BeebLibrary", "BeebNetwork", "BeebPrint"]

#if os(Linux)
targets += [
    // The app on GTK 4 and libadwaita (Sources/MacBeeb/Linux), around the
    // shared part (Sources/MacBeeb/Shared).
    .executableTarget(
        name: "MacBeeb",
        dependencies: appDependencies + ["CGtk", "CSDL3"],
        path: "Sources/MacBeeb",
        exclude: ["macOS"],
        sources: ["Shared", "Linux"]
    ),

    // The system libraries, through pkg-config. Ubuntu 26.04's packages:
    // libgtk-4-dev libadwaita-1-dev libepoxy-dev libsdl3-dev
    // libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libcairo2-dev
    // zlib1g-dev (scripts/linux-deps.sh installs them).
    .systemLibrary(name: "CGtk", pkgConfig: "libadwaita-1 gtk4 epoxy",
                   providers: [.apt(["libgtk-4-dev", "libadwaita-1-dev", "libepoxy-dev"])]),
    .systemLibrary(name: "CSDL3", pkgConfig: "sdl3", providers: [.apt(["libsdl3-dev"])]),
    .systemLibrary(name: "CGStreamer", pkgConfig: "gstreamer-1.0 gstreamer-app-1.0",
                   providers: [.apt(["libgstreamer1.0-dev", "libgstreamer-plugins-base1.0-dev"])]),
    .systemLibrary(name: "CCairo", pkgConfig: "cairo", providers: [.apt(["libcairo2-dev"])]),
    .systemLibrary(name: "CZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
    // Apple's reference LZFSE (BSD), for save states as the Mac writes them.
    .target(name: "CLZFSE", exclude: ["LICENSE", "README.md"], cSettings: [.unsafeFlags(["-w"])]),
]
#else
products += [
    .executable(name: "MacBeebQuickLook", targets: ["MacBeebQuickLook"]),
]
targets += [
    // The Mac app (Sources/MacBeeb/macOS), around the shared part
    // (Sources/MacBeeb/Shared).
    .executableTarget(
        name: "MacBeeb",
        dependencies: appDependencies + [.product(name: "Sparkle", package: "Sparkle")],
        path: "Sources/MacBeeb",
        exclude: ["Linux"],
        sources: ["Shared", "macOS"],
        // Sparkle.framework is embedded in Contents/Frameworks.
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),

    // Quick Look previews of disc images: an app extension, so it's
    // entered through NSExtensionMain. scripts/make-app.sh bundles it.
    .executableTarget(
        name: "MacBeebQuickLook",
        dependencies: ["BeebCore"],
        swiftSettings: [.unsafeFlags(["-application-extension"])],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                                       "-Xlinker", "-application_extension"])]
    ),
]
#endif

let package = Package(
    name: "macbeeb",
    platforms: [.macOS(.v26)],
    products: products,
    dependencies: [
        // Software updates for the Mac app. (Resolved on Linux too, so
        // Package.resolved is the same on both, but not built there.)
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: targets
)
