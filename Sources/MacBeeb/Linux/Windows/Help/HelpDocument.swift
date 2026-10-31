import CGtk
import Foundation

/// Markdown shown as GNOME shows text: a widget for each block (headings,
/// paragraphs with their bold, italic, code and links, lists, code in a
/// card with a Copy button, quotes, tables as grids, pictures, rules), all
/// selectable, for the guides, the credits and the release notes. (The
/// Mac's is GuideDocumentView.)
@MainActor
final class HelpDocument {
    /// Where the document's pictures are.
    let base: URL?
    /// A link chosen: true when it's been dealt with. Otherwise web links
    /// open in the browser.
    private let follow: (String) -> Bool
    /// Its headings, by anchor ("with-a-shadow-ram-board"), to scroll to.
    private(set) var anchors: [String: Widget] = [:]

    init(base: URL? = nil, onLink: @escaping (String) -> Bool = { _ in false }) {
        self.base = base
        follow = onLink
        HelpStyles.install()
    }

    /// The blocks, one under another.
    func view(_ blocks: [HelpMarkdown.Block]) -> Box {
        let box = Box(.vertical, spacing: 12).style("help-document")
        for (index, block) in blocks.enumerated() {
            box.append(widget(block, depth: 0, first: index == 0))
        }
        return box
    }

    /// Inline Markdown in a label that wraps, can be selected, and follows
    /// its links.
    func text(_ markdown: String) -> Label {
        let label = Label(markup: HelpMarkdown.markup(markdown)).wrap().selectable().style("help-text")
        let follow = follow
        label.onLink { uri in Self.open(uri, follow) }
        return label
    }

    /// A link: the handler's, or the browser's for the web; others (a page
    /// that isn't there) go nowhere.
    static func open(_ uri: String, _ handler: (String) -> Bool) -> Bool {
        if handler(uri) { return true }
        if let url = URL(string: uri), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            Platform.open(url)
        }
        return true
    }

    private func widget(_ block: HelpMarkdown.Block, depth: Int, first: Bool) -> Widget {
        switch block {
        case .heading(let level, let text):
            return heading(level, text, first: first)
        case .paragraph(let text):
            return self.text(text)
        case .list(let ordered, let start, let items):
            return list(ordered: ordered, start: start, items: items, depth: depth)
        case .code(let code):
            return Self.code(code)
        case .quote(let blocks):
            let content = Box(.vertical, spacing: 8)
            for (index, block) in blocks.enumerated() {
                content.append(widget(block, depth: depth, first: index == 0))
            }
            return Box(.horizontal) { content.expand(horizontal: true) }.style("help-quote")
        case .table(let header, let alignments, let rows):
            return table(header: header, alignments: alignments, rows: rows)
        case .image(let path, let alt):
            return image(path, alt: alt)
        case .rule:
            return Separator().margin(vertical: 6)
        }
    }

    private func heading(_ level: Int, _ text: String, first: Bool) -> Widget {
        // A heading to screen readers too, at its level.
        let label = Widget(macbeeb_help_heading_label(Int32(level)))
        let pointer = label.opaque
        gtk_label_set_markup(pointer, HelpMarkdown.markup(text))
        gtk_label_set_xalign(pointer, 0)
        gtk_label_set_wrap(pointer, 1)
        gtk_label_set_wrap_mode(pointer, PANGO_WRAP_WORD_CHAR)
        gtk_label_set_selectable(pointer, 1)
        switch level {
        case 1: label.style("title-1")
        case 2: label.style("title-2")
        case 3: label.style("title-3")
        default: label.style("title-4")
        }
        if !first {
            label.margin(top: level <= 2 ? 18 : level == 3 ? 10 : 4)
        }
        var anchor = HelpMarkdown.anchor(text)
        // (As GitHub numbers headings that are the same.)
        if anchors[anchor] != nil {
            var n = 1
            while anchors["\(anchor)-\(n)"] != nil { n += 1 }
            anchor += "-\(n)"
        }
        anchors[anchor] = label
        return label
    }

    private func list(ordered: Bool, start: Int, items: [[HelpMarkdown.Block]], depth: Int) -> Widget {
        let list = Box(.vertical, spacing: 6)
        let digits = Int32(String(start + items.count - 1).count + 1)
        for (index, item) in items.enumerated() {
            let marker: Label
            if ordered {
                marker = Label("\(start + index).", style: "dim-label", "numeric", "help-text").widthChars(digits).xalign(1)
            } else {
                marker = Label(depth == 0 ? "•" : "◦", style: "dim-label", "help-text")
            }
            marker.align(vertical: GTK_ALIGN_START)
            let content = Box(.vertical, spacing: 8).expand(horizontal: true)
            for (offset, block) in item.enumerated() {
                content.append(widget(block, depth: depth + 1, first: offset == 0))
            }
            list.append(Box(.horizontal, spacing: 8) { marker; content })
        }
        return list
    }

    /// Code: monospace, as written, scrolling sideways if it's wide, with
    /// a button to copy it.
    static func code(_ code: String) -> Widget {
        let label = Label(code, style: "monospace").selectable()
            .margin(top: 10, bottom: 10, start: 14, end: 14)
        let scroller = ScrolledWindow(label, horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER)
            .expand(horizontal: true)
        let copy = copyButton(code).align(vertical: GTK_ALIGN_START).margin(5)
        return Box(.horizontal) { scroller; copy }.style("card", "help-code")
    }

    /// A button that copies `text`, showing it has for a moment.
    static func copyButton(_ text: String) -> Button {
        let button = Button(icon: "edit-copy-symbolic").style("flat", "circular").tooltip("Copy").accessibleLabel("Copy")
        let life = WidgetLife(button)
        button.onClicked {
            Clipboard.setText(text)
            button.iconName = "object-select-symbolic"
            button.tooltip("Copied")
            macbeeb_announce(button.widget, "Copied")
            life.generation += 1
            let generation = life.generation
            MainLoop.after(1.5) {
                guard life.alive, life.generation == generation else { return }
                button.iconName = "edit-copy-symbolic"
                button.tooltip("Copy")
            }
        }
        return button
    }

    private func table(header: [String]?, alignments: [HelpMarkdown.Alignment], rows: [[String]]) -> Widget {
        let grid = Grid(rowSpacing: 8, columnSpacing: 20)
        let columns = max(header?.count ?? 0, rows.map(\.count).max() ?? 0)
        func cell(_ markdown: String, column: Int, bold: Bool) -> Label {
            let label = text(markdown)
            gtk_label_set_wrap_mode(cast(label.widget), PANGO_WRAP_WORD)
            label.align(vertical: GTK_ALIGN_START)
            switch column < alignments.count ? alignments[column] : .leading {
            case .leading: break
            case .center: label.xalign(0.5).justify(GTK_JUSTIFY_CENTER)
            case .trailing: label.xalign(1).justify(GTK_JUSTIFY_RIGHT)
            }
            if bold { label.style("heading") }
            // The last column takes what room's left.
            if column == columns - 1 { label.expand(horizontal: true) }
            return label
        }
        var row: Int32 = 0
        if let header {
            for (column, title) in header.enumerated() {
                grid.attach(cell(title, column: column, bold: true), column: Int32(column), row: row)
            }
            grid.attach(Separator(), column: 0, row: row + 1, width: Int32(max(columns, 1)))
            row += 2
        }
        for (index, cells) in rows.enumerated() {
            if index > 0 {
                grid.attach(Separator().style("help-row-separator"), column: 0, row: row, width: Int32(max(columns, 1)))
                row += 1
            }
            for (column, text) in cells.enumerated() {
                grid.attach(cell(text, column: column, bold: false), column: Int32(column), row: row)
            }
            row += 1
        }
        // (Not in a scroller: one measures its height at its narrowest. The
        // cells wrap at words instead.)
        grid.margin(top: 12, bottom: 12, start: 16, end: 16)
        return Bin(grid).style("card", "help-table")
    }

    /// A picture from the document's folder, at its own size (a Retina
    /// screenshot at half its pixels) up to 640 wide, smaller if the
    /// window is.
    private func image(_ path: String, alt: String) -> Widget {
        var error: UnsafeMutablePointer<GError>?
        guard let url = base?.appendingPathComponent(path),
              let texture = gdk_texture_new_from_filename(url.path, &error) else {
            if let error { g_error_free(error) }
            return Label(alt, style: "dim-label").wrap()
        }
        let picture = Picture(PlatformImage(texture: texture)).canShrink(true).tooltip(alt)
        gtk_picture_set_alternative_text(cast(picture.widget), alt)
        let frame = Bin(picture).style("card", "help-image")
        gtk_widget_set_overflow(frame.widget, GTK_OVERFLOW_HIDDEN)
        let width = Int32(min(Self.pointSize(of: url)?.width ?? 640, 640))
        let clamp = Clamp(frame, maximum: width)
        adw_clamp_set_tightening_threshold(cast(clamp.widget), width)
        return clamp.align(horizontal: GTK_ALIGN_START).margin(vertical: 4)
    }

    /// A document, scrolling: its pictures at their full height (a
    /// scroller's own viewport would give them their least, nothing).
    static func scroller(_ content: Widget) -> ScrolledWindow {
        let viewport = gtk_viewport_new(nil, nil)!
        gtk_viewport_set_child(cast(viewport), content.widget)
        gtk_viewport_set_scroll_to_focus(cast(viewport), 1)
        gtk_scrollable_set_vscroll_policy(OpaquePointer(viewport), GTK_SCROLL_NATURAL)
        return ScrolledWindow(Widget(viewport), horizontal: GTK_POLICY_NEVER).expand()
    }

    /// A PNG's size in points: its pixels, halved at 144 dpi (pHYs).
    static func pointSize(of url: URL) -> (width: Int, height: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The signature, IHDR, and what follows it (pHYs comes before the
        // picture's data).
        guard let data = try? handle.read(upToCount: 4096), data.count > 33,
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        let width = u32(16), height = u32(20)
        var scale = 1
        var at = 8
        while at + 8 <= bytes.count {
            let length = u32(at)
            let type = String(decoding: bytes[(at + 4)..<(at + 8)], as: UTF8.self)
            if type == "pHYs", at + 17 <= bytes.count, bytes[at + 16] == 1 {
                // Pixels per metre: 2835 is 72 dpi.
                scale = max(1, Int((Double(u32(at + 8)) / 2835).rounded()))
                break
            }
            if type == "IDAT" { break }
            at += 12 + length
        }
        return (width / scale, height / scale)
    }
}

/// Whether a widget's still there (for something done to it later).
@MainActor
final class WidgetLife {
    private(set) var alive = true
    var generation = 0

    init(_ widget: Widget) {
        widget.onDestroy { [self] in alive = false }
    }
}

/// The help windows' own styles, beside libadwaita's.
@MainActor
enum HelpStyles {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let css = """
        .help-text { line-height: 1.3; }
        .help-document > label.title-1 { margin-bottom: 2px; }
        .help-quote {
            border-left: 4px solid var(--accent-color);
            background-color: color-mix(in srgb, var(--accent-bg-color) 9%, transparent);
            border-radius: 4px 8px 8px 4px;
            padding: 10px 14px;
        }
        .help-image { border-radius: 8px; }
        .help-table separator.help-row-separator { opacity: 0.5; }
        .help-badge {
            background-color: color-mix(in srgb, var(--accent-bg-color) 18%, transparent);
            color: var(--accent-color);
            border-radius: 999px;
            padding: 1px 7px;
            font-size: 0.72em;
            font-weight: 800;
        }
        .help-command label { padding: 2px 0; }
        """
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}
