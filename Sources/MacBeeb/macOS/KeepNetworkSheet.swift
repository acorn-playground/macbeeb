import AppKit
import SwiftUI

/// Closing a new network, as closing a new document does: keep it, with a
/// name and a place, or delete it.
struct KeepNetworkSheet: View {
    let session: NetworkSession
    /// Kept or deleted: the window can close. Cancelled: it stays.
    let finished: (_ close: Bool) -> Void
    @State private var name = ""
    @State private var folder = RecentNetworks.folder
    @State private var error: String?

    private var folders: [(String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var list = [("MacBeeb Networks", RecentNetworks.folder),
                    ("Documents", home.appendingPathComponent("Documents")),
                    ("Desktop", home.appendingPathComponent("Desktop"))]
        if !list.contains(where: { $0.1 == folder }) { list.append((folder.lastPathComponent, folder)) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Do you want to keep this new network “\(session.project.name)”?")
                        .font(.headline)
                    Text("You can save it, with its machines, discs and layout, to open again, or delete it now.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Save As:")
                        .gridColumnAlignment(.trailing)
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                }
                GridRow {
                    Text("Where:")
                    Picker("Where", selection: $folder) {
                        ForEach(folders, id: \.1) { title, url in
                            Label(title, systemImage: "folder").tag(url)
                        }
                        Divider()
                        Text("Other…").tag(URL(fileURLWithPath: "/other"))
                    }
                    .labelsHidden()
                    .onChange(of: folder) { old, new in
                        if new.path == "/other" { folder = chooseFolder() ?? old }
                    }
                }
            }
            .padding(.leading, 48)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Delete", role: .destructive) {
                    Task {
                        await session.discard()
                        finished(true)
                    }
                }
                .help("Close the network and move it to the Trash")
                Spacer()
                Button("Cancel") { finished(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { name = session.project.name }
    }

    private func save() {
        do {
            try session.keep(as: name, in: folder)
            finished(true)
        } catch {
            self.error = "Couldn't save it there: \(error.localizedDescription)"
        }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Asks before its window closes: `shouldClose` says whether it may (and
/// can start asking instead). SwiftUI can't refuse a close itself, so this
/// stands in for the window's delegate, passing everything else on.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool
    /// Given the window, for closing it once it's allowed.
    var window: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.shouldClose = shouldClose
        view.onWindow = window
    }

    final class GuardView: NSView {
        var shouldClose: () -> Bool = { true }
        var onWindow: (NSWindow) -> Void = { _ in }
        private var proxy: Proxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.delegate is Proxy) else { return }
            let proxy = Proxy(original: window.delegate) { [weak self] in self?.shouldClose() ?? true }
            self.proxy = proxy
            window.delegate = proxy
            onWindow(window)
        }
    }

    final class Proxy: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?
        let shouldClose: () -> Bool

        init(original: NSWindowDelegate?, shouldClose: @escaping () -> Bool) {
            self.original = original
            self.shouldClose = shouldClose
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
