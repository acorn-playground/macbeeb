import AppKit
import SwiftUI

/// Help > Hardware Expansion Guide: the guides in docs/hardware-expansions,
/// shown in the app. The app bundle has them in Contents/Resources/Guides
/// (scripts/make-app.sh copies them); run from the source tree, they're
/// read from docs/ directly, so they're never out of step.
struct GuideWindow: View {
    static let windowID = "guide"
    /// The page to show first: a file name without .md.
    let initialPage: String?
    @State private var page: String?
    @State private var history: [String] = []

    init(page: String?) {
        initialPage = page
        _page = State(initialValue: page ?? Guide.pages.first?.id)
    }

    var body: some View {
        NavigationSplitView {
            List(Guide.pages, selection: $page) { entry in
                Label(entry.title, systemImage: entry.symbol)
                    .tag(entry.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            if let page, let document = Guide.document(page) {
                ScrollViewReader { proxy in
                    ScrollView {
                        GuideDocumentView(blocks: document)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 24)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity)
                            .id("top")
                    }
                    .onChange(of: page) { proxy.scrollTo("top", anchor: .top) }
                }
                .environment(\.openURL, OpenURLAction { url in open(url) })
            } else {
                ContentUnavailableView("No guide", systemImage: "book.closed",
                                       description: Text("The guides weren’t found in the app."))
            }
        }
        .navigationTitle(Guide.pages.first { $0.id == page }?.title ?? "Hardware Expansion Guide")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") {
                    page = history.popLast()
                }
                .disabled(history.isEmpty)
            }
        }
        .onChange(of: page) { old, _ in
            if let old, history.last != old { history.append(old) }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    /// Links between guides stay in the window; the rest open in the
    /// browser.
    private func open(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == nil || url.isFileURL {
            let name = (url.path as NSString).lastPathComponent
            let id = (name as NSString).deletingPathExtension
            if Guide.pages.contains(where: { $0.id == id }) {
                page = id
                return .handled
            }
        }
        return .systemAction
    }
}

/// The guide pages and their files.
enum Guide {
    struct Page: Identifiable, Hashable {
        var id: String
        var title: String
        var symbol: String
    }

    /// In reading order.
    static let order: [(String, String)] = [
        ("README", "book"),
        ("rom-sockets", "cpu"),
        ("sideways-ram", "memorychip"),
        ("watford-shadow-ram", "square.2.layers.3d"),
        ("aries-b32-b12", "square.3.layers.3d"),
        ("videonula", "paintpalette"),
        ("developer-reference", "chevron.left.forwardslash.chevron.right"),
        ("vscode", "ladybug"),
        ("network-studio", "point.3.connected.trianglepath.dotted"),
        ("ai-agents", "brain"),
    ]

    static var folder: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Guides/hardware-expansions"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Run from the source tree: Sources/MacBeeb/macOS/GuideWindow.swift ->
        // docs/hardware-expansions.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/hardware-expansions")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    static let pages: [Page] = order.compactMap { id, symbol in
        guard let text = text(id) else { return nil }
        let title = text.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? id
        return Page(id: id, title: title, symbol: symbol)
    }

    static func text(_ id: String) -> String? {
        guard var url = folder?.appendingPathComponent("\(id).md") else { return nil }
        // The Network Studio's guide lives in its own folder in the source.
        if id == "network-studio" && !FileManager.default.fileExists(atPath: url.path) {
            url = folder!.deletingLastPathComponent().appendingPathComponent("network-studio/README.md")
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func document(_ id: String) -> [GuideBlock]? {
        text(id).map { GuideBlock.parse($0, base: folder) }
    }
}

/// A Markdown block, as the guides use them.
enum GuideBlock: Hashable {
    case heading(Int, String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case code(String)
    case quote(String)
    case table([[String]])
    case image(URL, String)
    case rule

    static func parse(_ text: String, base: URL?) -> [GuideBlock] {
        var blocks: [GuideBlock] = []
        var lines = text.components(separatedBy: "\n")[...]
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(next)
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if let level = trimmed.firstIndex(where: { $0 != "#" }).map({ trimmed.distance(from: trimmed.startIndex, to: $0) }),
                      level > 0, level <= 4, trimmed.dropFirst(level).hasPrefix(" ") {
                flush()
                blocks.append(.heading(level, String(trimmed.dropFirst(level + 1))))
            } else if trimmed == "---" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("!["), let close = trimmed.firstIndex(of: "]"),
                      let open = trimmed[close...].firstIndex(of: "("), trimmed.hasSuffix(")") {
                flush()
                let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close])
                let path = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
                if let base { blocks.append(.image(base.appendingPathComponent(path), alt)) }
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows = [trimmed]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(next.trimmingCharacters(in: .whitespaces))
                    lines.removeFirst()
                }
                // A \| in a cell is a literal bar, not a column.
                let cells = rows.map { row in
                    row.replacingOccurrences(of: "\\|", with: "\u{1}")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{1}", with: "|") }
                }
                // Drop the |---|---| separator.
                blocks.append(.table(cells.filter { !$0.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                var items = [String(trimmed.dropFirst(2))]
                while let next = lines.first {
                    let t = next.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") || t.hasPrefix("* ") {
                        items.append(String(t.dropFirst(2)))
                    } else if !t.isEmpty && next.hasPrefix("  ") {
                        items[items.count - 1] += " " + t
                    } else {
                        break
                    }
                    lines.removeFirst()
                }
                blocks.append(.bullets(items))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
                      trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                var items = [String(trimmed[trimmed.index(dot, offsetBy: 2)...])]
                while let next = lines.first {
                    let t = next.trimmingCharacters(in: .whitespaces)
                    if let d = t.firstIndex(of: "."), t[..<d].allSatisfy(\.isNumber), !t[..<d].isEmpty, t[t.index(after: d)...].hasPrefix(" ") {
                        items.append(String(t[t.index(d, offsetBy: 2)...]))
                    } else if !t.isEmpty && next.hasPrefix("   ") {
                        items[items.count - 1] += " " + t
                    } else {
                        break
                    }
                    lines.removeFirst()
                }
                blocks.append(.numbered(items))
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(next.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    lines.removeFirst()
                }
                blocks.append(.quote(quote.joined(separator: " ")))
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return blocks
    }
}

private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

struct GuideDocumentView: View {
    let blocks: [GuideBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ block: GuideBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .largeTitle.weight(.semibold) : level == 2 ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .padding(.top, level == 1 ? 0 : 10)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inline(text))
                .font(.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 4)
                Text(inline(text))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .font(index == 0 ? .callout.weight(.semibold) : .callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        case .image(let url, let alt):
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 640))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .accessibilityLabel(alt)
            }
        case .rule:
            Divider()
        }
    }
}

/// Help > Hardware Expansion Guide.
struct GuideMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Hardware Expansion Guide") { openWindow(id: GuideWindow.windowID, value: "README") }
        Button("Network Studio Guide") { openWindow(id: GuideWindow.windowID, value: "network-studio") }
        Button("AI Agents Guide") { openWindow(id: GuideWindow.windowID, value: "ai-agents") }
        VSCodeGuideMenuItem()
    }
}

/// Help > Debugging with VS Code (also in the Debug menu).
struct VSCodeGuideMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Debugging with VS Code Guide") { openWindow(id: GuideWindow.windowID, value: "vscode") }
    }
}

