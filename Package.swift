// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macbeeb",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BeebCore", targets: ["BeebCore"]),
        .library(name: "BeebCapture", targets: ["BeebCapture"]),
        .library(name: "BeebROMs", targets: ["BeebROMs"]),
        .library(name: "BeebLibrary", targets: ["BeebLibrary"]),
        .executable(name: "beeb", targets: ["beeb"]),
        .executable(name: "MacBeeb", targets: ["MacBeeb"]),
        .executable(name: "macbeeb-mcp", targets: ["macbeeb-mcp"]),
        .executable(name: "MacBeebQuickLook", targets: ["MacBeebQuickLook"]),
        .executable(name: "beeb-bench", targets: ["beeb-bench"]),
        .library(name: "BeebWasm", targets: ["BeebWasm"]),
        .executable(name: "BeebWasmModule", targets: ["BeebWasmModule"]),
        .executable(name: "m6502-gen", targets: ["m6502-gen"]),
    ],
    dependencies: [
        // Software updates for the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // The emulation core: pure Swift, no UI or platform frameworks.
        //
        // Runtime exclusivity checks on class properties cost ~6x in the
        // per-cycle hot loop, so they're off for the core. (Compile-time
        // checks still apply.)
        .target(
            name: "BeebCore",
            swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"])]
        ),

        // The standard ROM images and the co-processors' system discs
        // (Acorn and Digital Research copyright, not GPL).
        .target(name: "BeebROMs", dependencies: ["BeebCore"], resources: [.copy("ROMs"), .copy("Discs"), .copy("Sounds")]),

        // The BBC Micro Classics bookshelf's catalogue and covers, the
        // library of imported games, and quick saves.
        .target(name: "BeebLibrary", dependencies: ["BeebCore"], exclude: ["COVERS.md"],
                resources: [.copy("Covers"), .copy("Data")]),

        // Screenshots (and later, video recording).
        .target(name: "BeebCapture", dependencies: ["BeebCore"]),

        // Runs a machine on its own thread, paced by audio or the wall clock.
        .target(name: "BeebHost", dependencies: ["BeebCore", "BeebCapture", "BeebPrint"]),

        // Printing: jobs as the BBC sent them, laid out on pages, and PDFs.
        .target(name: "BeebPrint"),

        // Networks of machines: the saved project, templates, and the
        // network that runs them.
        .target(name: "BeebNetwork", dependencies: ["BeebCore", "BeebHost", "BeebROMs", "BeebPrint"]),

        .executableTarget(name: "beeb", dependencies: ["BeebCore", "BeebCapture", "BeebROMs"]),

        // Tools for AI agents to drive a machine, and the MCP server.
        .target(name: "BeebAgentKit", dependencies: ["BeebCore", "BeebHost", "BeebCapture", "BeebROMs"]),
        // The Debug Adapter Protocol server, for VS Code and other editors.
        .target(name: "BeebDAP", dependencies: ["BeebCore", "BeebHost", "BeebROMs", "BeebAgentKit"]),
        .executableTarget(name: "macbeeb-mcp", dependencies: ["BeebAgentKit", "BeebCore", "BeebHost", "BeebROMs"]),

        // The Mac app.
        .executableTarget(
            name: "MacBeeb",
            dependencies: ["BeebCore", "BeebHost", "BeebCapture", "BeebROMs", "BeebAgentKit", "BeebDAP", "BeebLibrary",
                           "BeebNetwork", "BeebPrint", .product(name: "Sparkle", package: "Sparkle")],
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
                           "BeebNetwork", "BeebPrint", "M6502GenKit"],
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
)
