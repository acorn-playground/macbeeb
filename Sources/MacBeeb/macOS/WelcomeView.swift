import AppKit
import BeebLibrary
import BeebNetwork
import BeebROMs
import SwiftUI

/// The first thing MacBeeb shows (unless Settings says otherwise): its
/// three parts, a BBC Micro, the Game Library and the Network Studio, and
/// things worth trying, so there's a way into all of it.
struct WelcomeView: View {
    static let windowID = "welcome"
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(LaunchScreen.defaultsKey) private var launchScreen = LaunchScreen.preference
    @State private var error: String?
    /// Whether the launch has been dealt with (the Network Studio setting
    /// passes straight through).
    @MainActor private static var launched = false
    /// What's New has notes the user hasn't seen (until they look).
    @MainActor private static var unseenNotes = false
    @State private var hasUnseenNotes = WelcomeView.unseenNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            hero
            HStack(alignment: .top, spacing: 18) {
                machineCard
                gamesCard
                networkCard
            }
            .fixedSize(horizontal: false, vertical: true)
            explore
            footer
        }
        .padding(.horizontal, 36)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: 1060)
        .background(WelcomeBackground())
        .preferredColorScheme(.dark)
        .onAppear(perform: arrived)
        .onOpenURL { url in
            if JoinRequests.isJoinLink(url) {
                JoinRequests.shared.handle(url)
                go { openWindow(id: JoinRoomView.windowID) }
            }
        }
        .alert("Can’t make the network", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func arrived() {
        guard !Self.launched else { return }
        Self.launched = true
        if LaunchScreen.atLaunch == .network {
            NetworkStudioCommands.showStudio(openWindow: openWindow)
            dismissWindow(id: Self.windowID)
        } else {
            // Its tile says so, rather than opening the notes.
            Self.unseenNotes = WhatsNew.shouldShowOnLaunch()
            hasUnseenNotes = Self.unseenNotes
        }
    }

    /// Opens a window and puts this one away.
    private func go(_ action: () -> Void) {
        action()
        dismissWindow(id: Self.windowID)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("MacBeeb")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                Text("The BBC Micro, on your Mac. Switch one on and type, play the classics, or wire up a classroom of them on Econet and watch them work together.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 470, alignment: .leading)
                TeletextStripe()
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
            BootScreen()
                .frame(width: 400, height: 250)
        }
    }

    // MARK: The three parts

    private var machineCard: some View {
        let saved = MachineConfigurations.shared.machines
        return WelcomeCard(colour: .red, symbol: "desktopcomputer", title: "BBC Micro",
                           blurb: "A Model B, B+, Master 128 or Compact. Add a second processor, plug ROMs and cartridges into its sockets, and step through its 6502 in the debugger.") {
            ModelChips()
        } actions: {
            if !saved.isEmpty {
                WideMenu(title: "Start One of Your Machines",
                         items: saved.map { machine in (machine.name, { go { open(machine) } }) })
                .help("A machine configuration you've saved")
            }
            Button { go { openWindow(id: MachineWindow.windowID) } } label: {
                Label("Switch On", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .help("Open a BBC Micro, set up as the last one was")
        }
    }

    private func open(_ saved: SavedMachine) {
        MachineController.pendingLaunch = { $0.use(saved.setup) }
        openWindow(id: MachineWindow.windowID)
    }

    private var gamesCard: some View {
        WelcomeCard(colour: .yellow, symbol: "books.vertical", title: "Game Library",
                    blurb: "Elite, Repton, Chuckie Egg, Exile and more, with their box art, set up and ready to play. Add your own discs, and keep your saves.") {
            CoverFan()
        } actions: {
            Button { go { openWindow(id: BookshelfView.windowID) } } label: {
                Label("Browse Games", systemImage: "gamecontroller")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
        }
    }

    private var networkCard: some View {
        let recent = RecentNetworks.shared.existing
        return WelcomeCard(colour: .cyan, symbol: "point.3.connected.trianglepath.dotted", title: "Network Studio",
                           blurb: "A classroom of BBC Micros on Econet, each one running for real: file servers, printers, and messages and programs passed between them.") {
            EconetAnimation()
        } actions: {
            Button { go { openWindow(id: JoinRoomView.windowID) } } label: {
                Label("Join with a Code…", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Join someone's network over the Internet, with the code or link they gave you")
            if !recent.isEmpty {
                WideMenu(title: "Open Recent", items: recent.prefix(8).map { url in
                    (url.deletingPathExtension().lastPathComponent, { go { NetworkStudioCommands.open(url, openWindow: openWindow) } })
                })
            }
            Button { go { openWindow(id: NetworkStartView.windowID) } } label: {
                Label("New Network", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.large)
        }
    }

    // MARK: Explore

    private var explore: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Things to Try")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ExploreTile(symbol: "sparkles", colour: .purple, title: "Eight-BBC Mandelbrot",
                            detail: "In colour, over Econet") {
                    go(mandelbrot)
                }
                ExploreTile(symbol: "cpu", colour: .green, title: "Plug in ROMs",
                            detail: "Sockets and cartridges") {
                    go { openWindow(id: GuideWindow.windowID, value: "rom-sockets") }
                }
                ExploreTile(symbol: "brain", colour: .pink, title: "Let an AI drive",
                            detail: "Connect an agent with MCP") {
                    go { openWindow(id: MCPSetupView.windowID) }
                }
                ExploreTile(symbol: "gift", colour: .blue, title: "What’s new in \(WhatsNew.releases.first?.version ?? WhatsNew.currentVersion)",
                            detail: "Everything in this version", badge: hasUnseenNotes ? "New" : nil) {
                    Self.unseenNotes = false
                    hasUnseenNotes = false
                    openWindow(id: WhatsNewView.windowID)
                }
            }
        }
    }

    private func mandelbrot() {
        do {
            let url = try NetworkStudioCommands.createDraft(.mandelbrotInColour)
            NetworkStudioCommands.open(url, openWindow: openWindow)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("When MacBeeb opens, show")
                .foregroundStyle(.secondary)
            Picker("When MacBeeb opens, show", selection: $launchScreen) {
                ForEach(LaunchScreen.allCases) { screen in
                    Text(screen.title).tag(screen)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text("Window ▸ Welcome to MacBeeb brings this back.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Pieces

/// One of the three parts: a picture, what it is, and how in.
private struct WelcomeCard<Art: View, Actions: View>: View {
    let colour: Color
    let symbol: String
    let title: String
    let blurb: String
    @ViewBuilder var art: Art
    @ViewBuilder var actions: Actions
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            art
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(colour)
                Text(title)
                    .font(.title2.weight(.bold))
            }
            Text(blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                actions
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(hovering ? 0.085 : 0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(LinearGradient(colors: [colour.opacity(hovering ? 0.9 : 0.45), .white.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
        }
        .shadow(color: colour.opacity(hovering ? 0.35 : 0.0), radius: 22)
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.snappy(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// A smaller suggestion.
private struct ExploreTile: View {
    let symbol: String
    let colour: Color
    let title: String
    let detail: String
    var badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(colour)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(colour, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(hovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(colour.opacity(hovering ? 0.7 : 0), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}

/// The page behind it all: dark, with a glow of the BBC's colours.
private struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.075)
            RadialGradient(colors: [Color.red.opacity(0.22), .clear], center: UnitPoint(x: 0.05, y: 0.0), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color.cyan.opacity(0.16), .clear], center: UnitPoint(x: 1, y: 0.15), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color.yellow.opacity(0.08), .clear], center: UnitPoint(x: 0.5, y: 1.1), startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

/// The BBC Micro's function-key strip colours, as a rule under the title.
private struct TeletextStripe: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array([Color.red, .orange, .yellow, .green, .cyan, .blue, .purple].enumerated()), id: \.offset) { _, colour in
                Capsule()
                    .fill(colour.gradient)
                    .frame(width: 34, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The models, as chips.
private struct ModelChips: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.red.opacity(0.35), Color.red.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 6) {
                    ForEach(["Model B", "B+", "Master 128", "Compact"], id: \.self) { model in
                        Text(model)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.35), in: Capsule())
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Some of the library's covers, fanned out.
private struct CoverFan: View {
    static let names = ["chuckie-egg", "repton", "elite-copro", "exile-64k", "citadel"]
    static let images: [NSImage] = names.compactMap { name in
        BeebLibrary.bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Covers").flatMap(NSImage.init(contentsOf:))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.yellow.opacity(0.28), Color.orange.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ZStack {
                ForEach(Array(Self.images.enumerated()), id: \.offset) { index, image in
                    let middle = Double(Self.images.count - 1) / 2
                    let place = Double(index) - middle
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 70, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                        .rotationEffect(.degrees(place * 9), anchor: .bottom)
                        .offset(x: place * 40, y: abs(place) * 7 + 10)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// BBC Micros on a cable, with frames running along it.
private struct EconetAnimation: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let line = size.height * 0.7
                let stations = 4
                let xs = (0..<stations).map { size.width * (0.14 + 0.24 * Double($0)) }
                // The cable and the drops.
                var cable = Path()
                cable.move(to: CGPoint(x: size.width * 0.05, y: line))
                cable.addLine(to: CGPoint(x: size.width * 0.95, y: line))
                g.stroke(cable, with: .color(.cyan.opacity(0.55)), lineWidth: 2)
                for x in xs {
                    var drop = Path()
                    drop.move(to: CGPoint(x: x, y: line))
                    drop.addLine(to: CGPoint(x: x, y: line - 26))
                    g.stroke(drop, with: .color(.cyan.opacity(0.55)), lineWidth: 2)
                    let screen = CGRect(x: x - 22, y: line - 66, width: 44, height: 40)
                    g.fill(Path(roundedRect: screen, cornerRadius: 5), with: .color(.white.opacity(0.85)))
                    g.fill(Path(roundedRect: screen.insetBy(dx: 4, dy: 4), cornerRadius: 2), with: .color(.black))
                    for row in 0..<3 {
                        let width = [24.0, 16, 20][(row + Int(x)) % 3]
                        g.fill(Path(CGRect(x: screen.minX + 7, y: screen.minY + 8 + Double(row) * 7, width: width, height: 3)),
                               with: .color(.green.opacity(0.8)))
                    }
                }
                // Frames from one station to another and back.
                for packet in 0..<3 {
                    let phase = (time * 0.35 + Double(packet) / 3).truncatingRemainder(dividingBy: 1)
                    let from = xs[packet % stations], to = xs[(packet + 2) % stations]
                    let x = from + (to - from) * (0.5 - 0.5 * cos(phase * .pi * 2))
                    let dot = CGRect(x: x - 5, y: line - 5, width: 10, height: 10)
                    g.fill(Path(ellipseIn: dot.insetBy(dx: -5, dy: -5)), with: .color(.cyan.opacity(0.18)))
                    g.fill(Path(ellipseIn: dot), with: .color([Color.yellow, .green, .pink][packet]))
                }
            }
            .background(LinearGradient(colors: [Color.cyan.opacity(0.22), Color.blue.opacity(0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .accessibilityHidden(true)
    }
}

/// A BBC Micro's screen at power on, in its own font, typing things to try.
struct BootScreen: View {
    static let commands = ["CHAIN \"ELITE\"", "*CLUSTER", "MODE 2", "*NET", "PRINT \"HELLO\"", "*ROMS", "*IWORD", "RUN"]
    /// The OS 1.20 font: 8 bytes a character from space.
    static let font: [UInt8] = Array(BeebROMs.data(.os12).prefix(96 * 8))

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let lines = lines(at: time)
                let columns = 19.0
                let pixel = floor(size.width * 0.86 / (columns * 8))
                let lineHeight = 8 * pixel * 1.5
                let origin = CGPoint(x: (size.width - columns * 8 * pixel) / 2,
                                     y: (size.height - Double(lines.count) * lineHeight) / 2)
                for (row, line) in lines.enumerated() {
                    for (column, character) in line.unicodeScalars.enumerated() {
                        draw(Int(character.value), at: CGPoint(x: origin.x + Double(column) * 8 * pixel,
                                                               y: origin.y + Double(row) * lineHeight),
                             pixel: pixel, in: &g)
                    }
                }
                // Scan lines.
                var y = 0.0
                while y < size.height {
                    g.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.22)))
                    y += 3
                }
            }
            .background(Color(red: 0.02, green: 0.03, blue: 0.025))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.16)).shadow(color: .black.opacity(0.6), radius: 18, y: 8))
        .shadow(color: .green.opacity(0.18), radius: 30)
        .accessibilityElement()
        .accessibilityLabel("A BBC Micro's screen at power on: BBC Computer 32K, Acorn DFS, BASIC")
    }

    /// The boot text, then a command being typed (a few seconds each),
    /// with the cursor flashing.
    private func lines(at time: Double) -> [String] {
        let period = 4.0
        let index = Int(time / period) % Self.commands.count
        let into = time.truncatingRemainder(dividingBy: period)
        let command = Self.commands[index]
        let typed = String(command.prefix(max(0, Int((into - 0.6) * 9))))
        let cursor = Int(time * 2.5) % 2 == 0 ? "_" : " "
        return ["BBC Computer 32K", "", "Acorn DFS", "", "BASIC", "", ">" + typed + cursor]
            .map { String($0.prefix(19)) }
    }

    private func draw(_ character: Int, at point: CGPoint, pixel: Double, in g: inout GraphicsContext) {
        guard (32..<128).contains(character) else { return }
        let glyph = Self.font[(character - 32) * 8..<(character - 32) * 8 + 8]
        var path = Path()
        for (row, bits) in glyph.enumerated() {
            for bit in 0..<8 where bits & (0x80 >> bit) != 0 {
                path.addRect(CGRect(x: point.x + Double(bit) * pixel, y: point.y + Double(row) * pixel, width: pixel, height: pixel))
            }
        }
        g.fill(path, with: .color(Color(red: 0.92, green: 1, blue: 0.92)))
    }
}

/// Window > Welcome to MacBeeb.
struct WelcomeMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // (Menus are made at launch: the way to open the welcome screen
        // when no window's left to do it.)
        let _ = WelcomeReturn.remember(openWindow)
        Button("Welcome to MacBeeb") { openWindow(id: WelcomeView.windowID) }
            .keyboardShortcut("1", modifiers: [.command, .shift])
    }
}

/// A menu that looks like the card's other buttons, as wide as they are
/// (SwiftUI's menu button keeps to the width of its title): a button that
/// opens its menu where it was clicked.
private struct WideMenu: View {
    let title: String
    let items: [(String, () -> Void)]

    var body: some View {
        Button(action: show) {
            Text(title)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows a menu")
    }

    @MainActor
    private func show() {
        let menu = NSMenu()
        let target = MenuTarget(items.map(\.1))
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.0, action: #selector(MenuTarget.choose(_:)), keyEquivalent: "")
            entry.target = target
            entry.tag = index
            menu.addItem(entry)
        }
        // (Held by the menu's items while it's open.)
        withExtendedLifetime(target) {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @MainActor
    private final class MenuTarget: NSObject {
        let actions: [() -> Void]

        init(_ actions: [() -> Void]) {
            self.actions = actions
        }

        @objc func choose(_ item: NSMenuItem) {
            if actions.indices.contains(item.tag) { actions[item.tag]() }
        }
    }
}

/// With the welcome screen as the opening screen, MacBeeb is a place to
/// come back to: closing the last other window brings the welcome screen
/// back, and closing that quits (as closing the last window does
/// otherwise).
@MainActor
enum WelcomeReturn {
    private static var openWindow: OpenWindowAction?

    static var applies: Bool { LaunchScreen.preference == .welcome && !LaunchScreen.isSelfTest }

    static func remember(_ action: OpenWindowAction) {
        openWindow = action
    }

    static func open() {
        openWindow?(id: WelcomeView.windowID)
    }

    /// Opens another window (when no view's at hand to).
    static func open(id: String) {
        openWindow?(id: id)
    }

    static func start() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let title = (note.object as? NSWindow)?.title
            MainActor.assumeIsolated { closed(title: title) }
        }
    }

    /// A window's closing: once it's gone (and any window it opened has
    /// appeared, as the welcome screen's buttons open one as it closes),
    /// if nothing's left, the welcome screen comes back, or if it was the
    /// welcome screen, MacBeeb quits.
    private static func closed(title: String?) {
        guard applies else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            // (By then the closed window isn't visible.)
            let open = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            guard !open else { return }
            if title == "Welcome to MacBeeb" {
                NSApp.terminate(nil)
            } else {
                Self.open()
            }
        }
    }
}
