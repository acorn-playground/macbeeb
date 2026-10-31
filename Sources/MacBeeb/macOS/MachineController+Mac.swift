import AppKit
import BeebAgentKit
import BeebCapture
import BeebCore
import BeebDAP
import BeebHost
import BeebLibrary
import BeebNetwork
import BeebROMs
import Observation
import SwiftUI
import UniformTypeIdentifiers

// The Mac's own parts of MachineController: the file types its panels and
// drop targets take, rewind thumbnails as CGImages, and the self-tests,
// which drive the window through AppKit.

extension MachineController {
    static let discTypes: [UTType] = Disc.ImageFormat.extensions.map { UTType(filenameExtension: $0) ?? .data }

    static let tapeTypes: [UTType] = [
        UTType(filenameExtension: "uef") ?? .data,
        UTType(filenameExtension: "csw") ?? .data,
    ]

    static let stateType = UTType(filenameExtension: SaveStateFile.fileExtension) ?? .data

    /// A rewind point's thumbnail.
    func rewindThumbnail(_ index: Int) async -> CGImage? {
        guard let pixels = await rewindThumbnailPixels(index),
              let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 4) as CFData) else { return nil }
        return CGImage(width: Rewinder.thumbnailWidth, height: Rewinder.thumbnailHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Rewinder.thumbnailWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// `MacBeeb -MacBeebSelfTest /path/to/out.png`: types a command, then
    /// saves what the window is showing and quits. For checking the app
    /// end to end without looking at it.
    func runSelfTestIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "MacBeebSelfTest") else { return }
        let disc = UserDefaults.standard.string(forKey: "MacBeebSelfTestDisc")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if let disc, UserDefaults.standard.bool(forKey: "MacBeebSelfTestDiscKeys") {
                await typeThroughWindowWithDiscKeys(disc)
            } else if let disc {
                insertDisc(URL(fileURLWithPath: disc))
                try? await Task.sleep(for: .seconds(25))
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestRewind") {
                host.send(.type("PRINT \"BEFORE\"\n"))
                try? await Task.sleep(for: .seconds(2))
                host.send(.type("CLS\n"))
                try? await Task.sleep(for: .seconds(1))
                showingTimeline = true
                try? await Task.sleep(for: .seconds(1.5))
                if let sheet = NSApp.windows.compactMap(\.attachedSheet).first,
                   let frameView = sheet.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-rewind.png")))
                }
                // Back to before the CLS, still paused: the picture shows it.
                showingTimeline = false
                rewind(seconds: 4)
                try? await Task.sleep(for: .seconds(0.3))
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestProfile") {
                // A busy BASIC loop, profiled, with the Profile tab showing.
                UserDefaults.standard.set("Profile", forKey: "MacBeebDebuggerTab")
                host.send(.type("MODE 2\nREPEAT:GCOL0,RND(7):DRAW RND(1280),RND(1024):UNTIL FALSE\n"))
                try? await Task.sleep(for: .seconds(3))
                debugger.setProfiling(true)
                debuggerRequested = true
                try? await Task.sleep(for: .seconds(2))
                debugger.setProfiling(false)
                try? await Task.sleep(for: .seconds(0.5))
                if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Debugger") }),
                   let frameView = window.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-profile.png")))
                }
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestDebugger") {
                // Stop at OSWRCH as the key is echoed, then capture the
                // debugger window.
                debugger.addBreakpoint(Breakpoint(start: 0xFFEE))
                debugger.setTracing(true)
                try? await Task.sleep(for: .milliseconds(300))
                host.send(.type("P"))
                try? await Task.sleep(for: .seconds(2))
                if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Debugger") }),
                   let frameView = window.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-debugger.png")))
                }
            } else if let file = UserDefaults.standard.string(forKey: "MacBeebSelfTestBasicFile") {
                // A BASIC program, as if dropped on the window.
                runBASICProgram(URL(fileURLWithPath: file))
                try? await Task.sleep(for: .seconds(3))
            } else if let page = UserDefaults.standard.string(forKey: "MacBeebSelfTestGuide"), let blocks = Guide.document(page) {
                // A guide page, drawn offscreen at its full length.
                let view = NSHostingView(rootView: GuideDocumentView(blocks: blocks).padding(32).frame(width: 760)
                    .background(Color(nsColor: .windowBackgroundColor)))
                view.appearance = NSAppearance(named: .aqua)
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = view
                try? await Task.sleep(for: .seconds(1))
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-guide.png")))
                }
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestCredits") {
                // Help > Credits, drawn offscreen.
                let view = NSHostingView(rootView: CreditsWindow().background(Color(nsColor: .windowBackgroundColor)))
                view.appearance = NSAppearance(named: .aqua)
                view.frame = NSRect(x: 0, y: 0, width: 680, height: 720)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = view
                try? await Task.sleep(for: .seconds(1))
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-credits.png")))
                }
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestBasicDebugger") {
                // A program stopped at a BASIC breakpoint in a PROC, then
                // stepped, then stopped at an error: the debugger's BASIC
                // view each time.
                host.send(.paste("""
                10 total=0:DIM grid%(2,2)
                20 FOR I%=1 TO 3
                30 PROCadd(I%)
                40 NEXT
                50 PRINT total/0
                60 END
                100 DEF PROCadd(N%)
                110 LOCAL T,name$
                120 T=N%*2:name$="Step "+STR$N%
                130 total=total+T:grid%(N%-1,1)=T
                140 ENDPROC

                """))
                try? await Task.sleep(for: .seconds(1))
                debugger.addBasicBreakpoint(BasicBreakpoint(line: 130, condition: "N%=2"))
                debugger.setBasicErrorStop(.untrapped)
                debugger.addBasicWatch("total*10")
                debugger.addBasicWatch("grid%(0,1)")
                debugger.toggleBasicArray("grid%(")
                // (The commands run on the emulation thread.)
                try? await Task.sleep(for: .seconds(0.5))
                host.send(.paste("RUN\n"))
                debuggerRequested = true
                @MainActor func capture(_ suffix: String) {
                    if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Debugger") }),
                       let frameView = window.contentView?.superview,
                       let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(suffix).png")))
                    }
                }
                try? await Task.sleep(for: .seconds(2))
                capture("basic")
                debugger.basicStep(.into)
                try? await Task.sleep(for: .seconds(1))
                capture("basic-step")
                debugger.removeAllBasicBreakpoints()
                debugger.basicPauseOrContinue()
                try? await Task.sleep(for: .seconds(2))
                capture("basic-error")
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestMacLayout") {
                await typeThroughWindowInMacLayout()
            } else {
                host.send(.type("PRINT \"MACBEEB \";6*7\n"))
                try? await Task.sleep(for: .seconds(2))
            }
            let png = screenshotPNG()
            // The display as drawn, at twice the TV's size.
            if let image = renderer?.renderImage(width: EmulatorHost.Frame.width * 2, height: EmulatorHost.Frame.height * 2),
               let display = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? display.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-display.png")))
            }
            // The whole window, toolbar included.
            if let frameView = NSApp.windows.first(where: { $0.firstResponder is EmulatorNSView })?.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-window.png")))
            }
            let report = "frame=\(host.frame?.number ?? -1) cycles=\(host.cycles) audioQueued=\(host.audioRing.count)\n"
            FileManager.default.createFile(atPath: path + ".txt", contents: Data(report.utf8))
            if let png {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    /// Presses Q through the window with `disc` in drive 0, which has Q
    /// mapped to 9, then with it ejected, then Return: "9Q" is typed.
    private func typeThroughWindowWithDiscKeys(_ disc: String) async {
        let settings = KeyboardSettings.shared
        let path = URL(fileURLWithPath: disc).standardizedFileURL.path
        defer { settings.removeAllMappings(disc: path) }
        settings.setMapping(keyCode: 0x0C, macKeyName: "Q", to: .digit9, disc: path)
        insertDisc(URL(fileURLWithPath: disc), boot: false)
        try? await Task.sleep(for: .milliseconds(200))
        guard let window = NSApp.windows.first(where: { $0.firstResponder is EmulatorNSView }),
              let view = window.firstResponder as? EmulatorNSView else { return }
        func key(_ code: UInt16, _ characters: String) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: code) else { continue }
                if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        await key(0x0C, "q")
        ejectDisc(drive: 0)
        try? await Task.sleep(for: .milliseconds(200))
        await key(0x0C, "q")
        await key(0x24, "\r")
        try? await Task.sleep(for: .seconds(1))
    }

    /// Types PRINT 6*7 as Mac key events through the window, with "*" as
    /// Shift-8 (US/UK layouts), in Mac layout mode.
    private func typeThroughWindowInMacLayout() async {
        let settings = KeyboardSettings.shared
        let savedMode = settings.mode
        settings.mode = .macLayout
        defer { settings.mode = savedMode }
        try? await Task.sleep(for: .milliseconds(100))
        guard let window = NSApp.windows.first(where: { $0.firstResponder is EmulatorNSView }),
              let view = window.firstResponder as? EmulatorNSView else { return }

        func key(_ code: UInt16, _ characters: String, shift: Bool = false) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: code) else { continue }
                if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        func shift(_ down: Bool) async {
            guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? .shift : [],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "", charactersIgnoringModifiers: "",
                                               isARepeat: false, keyCode: 0x38) else { return }
            view.flagsChanged(with: event)
            try? await Task.sleep(for: .milliseconds(60))
        }

        for (code, character) in [(UInt16(0x23), "P"), (0x0F, "R"), (0x22, "I"), (0x2D, "N"), (0x11, "T"),
                                  (0x31, " "), (0x16, "6")] {
            await key(code, character)
        }
        await shift(true)
        await key(0x1C, "*", shift: true)
        await shift(false)
        await key(0x1A, "7")
        await key(0x24, "\r")
        try? await Task.sleep(for: .seconds(1))
    }
}
