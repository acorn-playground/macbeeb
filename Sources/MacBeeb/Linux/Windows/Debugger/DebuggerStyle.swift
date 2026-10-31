import BeebCore
import BeebHost
import CGtk
import Foundation

// The debugger's look: its fonts (the desktop's monospace font, as the
// Mac's code views use its own), its colours (the theme's, light or dark),
// its styles, and text drawn quickly into its custom-drawn views.

/// The code font: the desktop's monospace font (GNOME's setting, through
/// libadwaita), a point smaller and two points smaller (the Mac's body and
/// callout monospaced fonts). Views opened after the setting changes take
/// its new size; those open redraw in its new face.
@MainActor
enum CodeFont {
    /// "Ubuntu Sans Mono 11", "Adwaita Mono 11"…
    private static var name: String {
        String(gBorrowed: adw_style_manager_get_monospace_font_name(adw_style_manager_get_default())) ?? "Monospace 11"
    }

    private typealias Fonts = (code: OpaquePointer, small: OpaquePointer, ui: OpaquePointer, heading: OpaquePointer,
                               caption: OpaquePointer)
    private static var cached: (name: String, fonts: Fonts)?

    private static func fonts() -> Fonts {
        let name = self.name
        if let cached, cached.name == name {
            return cached.fonts
        }
        if let old = cached?.fonts {
            [old.code, old.small, old.ui, old.heading, old.caption].forEach { pango_font_description_free($0) }
        }
        let code = pango_font_description_from_string(name)!
        var size = Double(pango_font_description_get_size(code)) / Double(PANGO_SCALE)
        if size <= 0 { size = 11 }
        // The monospace setting is for long text: a touch smaller is the
        // Mac's dense code views' size.
        pango_font_description_set_size(code, Int32((size - 1) * Double(PANGO_SCALE)))
        let small = pango_font_description_copy(code)!
        pango_font_description_set_size(small, Int32((size - 2) * Double(PANGO_SCALE)))
        let ui = pango_font_description_from_string(uiFontName)!
        let uiSize = Double(pango_font_description_get_size(ui)) / Double(PANGO_SCALE)
        // (A list's section heading: bold, a little smaller.)
        let heading = pango_font_description_copy(ui)!
        pango_font_description_set_weight(heading, PANGO_WEIGHT_BOLD)
        pango_font_description_set_size(heading, Int32((uiSize > 0 ? uiSize : 11) * 0.9 * Double(PANGO_SCALE)))
        // (libadwaita's caption: 82% of the interface font.)
        let caption = pango_font_description_copy(ui)!
        pango_font_description_set_size(caption, Int32((uiSize > 0 ? uiSize : 11) * 0.82 * Double(PANGO_SCALE)))
        let fonts = (code, small, ui, heading, caption)
        cached = (name, fonts)
        return fonts
    }

    /// The interface font ("Adwaita Sans 11"), for headings in drawn views.
    private static var uiFontName: String {
        var value: UnsafeMutablePointer<CChar>?
        if let settings = gtk_settings_get_default() {
            withUnsafeMutablePointer(to: &value) { pointer in
                macbeeb_debugger_get_string_property(gpointer(settings), "gtk-font-name", pointer)
            }
        }
        return String(gOwned: value) ?? "Sans 11"
    }

    static var code: OpaquePointer { fonts().code }
    static var small: OpaquePointer { fonts().small }
    static var ui: OpaquePointer { fonts().ui }
    static var heading: OpaquePointer { fonts().heading }
    static var caption: OpaquePointer { fonts().caption }

    /// The CSS for widgets showing code (entries, labels): the same font.
    static var css: String {
        let description = code
        let family = String(cString: pango_font_description_get_family(description))
        let size = Double(pango_font_description_get_size(description)) / Double(PANGO_SCALE)
        let small = Double(pango_font_description_get_size(self.small)) / Double(PANGO_SCALE)
        return """
        .debugger-code { font-family: "\(family)"; font-size: \(size)pt; }
        .debugger-code-small { font-family: "\(family)"; font-size: \(small)pt; }
        row.debugger-code-title label.title { font-family: "\(family)"; font-size: \(size)pt; }
        row.debugger-code-entry text { font-family: "\(family)"; font-size: \(size)pt; }
        """
    }
}

/// The size of text in a font, measured with a widget's Pango context.
@MainActor
struct TextMetrics {
    /// One character's advance (the fonts are monospaced).
    var charWidth: Double
    var lineHeight: Double

    init(_ font: OpaquePointer, widget: Widget) {
        let layout = gtk_widget_create_pango_layout(widget.widget, "0000000000")!
        pango_layout_set_font_description(layout, font)
        var width: Int32 = 0, height: Int32 = 0
        pango_layout_get_size(layout, &width, &height)
        g_object_unref(gpointer(layout))
        charWidth = Double(width) / Double(PANGO_SCALE) / 10
        lineHeight = (Double(height) / Double(PANGO_SCALE)).rounded(.up)
    }
}

/// The theme's colours, as a drawn view needs them: the text colour (and
/// the dim-label's), the accent, and the palette's red and orange, each
/// as light or dark wants.
@MainActor
struct Palette {
    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    let foreground: RGBA
    let dark: Bool
    let accentBackground: RGBA
    let accentText: RGBA

    init(_ widget: Widget) {
        var rgba = GdkRGBA()
        gtk_widget_get_color(widget.widget, &rgba)
        foreground = (Double(rgba.red), Double(rgba.green), Double(rgba.blue), Double(rgba.alpha))
        let manager = adw_style_manager_get_default()
        dark = adw_style_manager_get_dark(manager) != 0
        if let accent = adw_style_manager_get_accent_color_rgba(manager) {
            accentBackground = (Double(accent.pointee.red), Double(accent.pointee.green), Double(accent.pointee.blue), 1)
            gdk_rgba_free(accent)
        } else {
            accentBackground = (0.21, 0.52, 0.89, 1)
        }
        var standalone = GdkRGBA()
        adw_accent_color_to_standalone_rgba(adw_style_manager_get_accent_color(manager), dark ? 1 : 0, &standalone)
        accentText = (Double(standalone.red), Double(standalone.green), Double(standalone.blue), 1)
    }

    static func hex(_ value: UInt32) -> RGBA {
        (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255, 1)
    }

    /// Text that's less important (libadwaita's dim-label opacity).
    var secondary: RGBA { (foreground.r, foreground.g, foreground.b, foreground.a * 0.55) }
    /// Outlines and faint things.
    var faint: RGBA { (foreground.r, foreground.g, foreground.b, foreground.a * 0.25) }
    /// A breakpoint's red (GNOME's red 3).
    var breakpoint: RGBA { Self.hex(0xE01B24) }
    /// Red text: errors.
    var errorText: RGBA { Self.hex(dark ? 0xFF7B63 : 0xC01C28) }
    /// Orange text: changed bytes.
    var changedText: RGBA { Self.hex(dark ? 0xFFA348 : 0xE66100) }
    /// The profile's heat (GNOME's orange 3).
    var heat: RGBA { Self.hex(0xFF7800) }
}

extension Cairo {
    func color(_ rgba: Palette.RGBA, alpha: Double = 1) {
        color(rgba.r, rgba.g, rgba.b, rgba.a * alpha)
    }
}

/// Text drawn into a view, with one Pango layout for the whole drawing
/// (Cairo.text makes one for each piece of text, too slow for views of
/// hundreds of pieces drawn many times a second).
@MainActor
final class TextPainter {
    let cairo: Cairo
    private let layout: OpaquePointer
    private var font: OpaquePointer?
    private var width: Double?

    private init(_ cairo: Cairo) {
        self.cairo = cairo
        layout = pango_cairo_create_layout(cairo.context)
    }

    /// Paints with a painter for the duration of `body`.
    static func paint(_ cairo: Cairo, _ body: (TextPainter) -> Void) {
        let painter = TextPainter(cairo)
        body(painter)
        g_object_unref(gpointer(painter.layout))
    }

    private func prepare(_ font: OpaquePointer, width: Double?) {
        if font != self.font {
            pango_layout_set_font_description(layout, font)
            self.font = font
        }
        if width != self.width {
            if let width {
                pango_layout_set_width(layout, Int32(max(0, width) * Double(PANGO_SCALE)))
                pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
            } else {
                pango_layout_set_width(layout, -1)
                pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_NONE)
            }
            self.width = width
        }
    }

    /// Draws `text` with its top left at (x, y), ellipsized to `width`;
    /// returns how wide it was.
    @discardableResult
    func text(_ text: String, x: Double, y: Double, font: OpaquePointer, color: Palette.RGBA, width: Double? = nil) -> Double {
        prepare(font, width: width)
        setText(text)
        return show(x: x, y: y, color: color)
    }

    /// Plain text (without the attributes markup left).
    private func setText(_ text: String) {
        if styled {
            pango_layout_set_attributes(layout, nil)
            styled = false
        }
        pango_layout_set_text(layout, text, -1)
    }

    private var styled = false

    /// Text with Pango markup (<b>, <u>…).
    @discardableResult
    func markup(_ markup: String, x: Double, y: Double, font: OpaquePointer, color: Palette.RGBA, width: Double? = nil) -> Double {
        prepare(font, width: width)
        pango_layout_set_markup(layout, markup, -1)
        styled = true
        return show(x: x, y: y, color: color)
    }

    /// Text ending at `right` (right-aligned).
    @discardableResult
    func text(_ text: String, right: Double, y: Double, font: OpaquePointer, color: Palette.RGBA, maxWidth: Double? = nil) -> Double {
        prepare(font, width: maxWidth)
        setText(text)
        let width = measured
        return show(x: right - width, y: y, color: color)
    }

    private var measured: Double {
        var width: Int32 = 0, height: Int32 = 0
        pango_layout_get_size(layout, &width, &height)
        return Double(width) / Double(PANGO_SCALE)
    }

    private func show(x: Double, y: Double, color: Palette.RGBA) -> Double {
        cairo.color(color)
        cairo.move(x, y)
        pango_cairo_show_layout(cairo.context, layout)
        return measured
    }
}

// MARK: Styles

@MainActor
enum DebuggerStyles {
    private static var provider: UnsafeMutablePointer<GtkCssProvider>?
    private static var installedFor = ""

    /// The debugger's own CSS (installed once, and again when the
    /// monospace font setting changes).
    static func install() {
        let css = CodeFont.css + """

        .debugger-view { background-color: var(--view-bg-color); }
        .debugger-pane-header { min-height: 34px; }
        .debugger-flag { min-width: 26px; padding-left: 4px; padding-right: 4px; }
        .debugger-flag:checked { background-color: var(--accent-bg-color); color: var(--accent-fg-color); }
        .debugger-error-bar { background-color: color-mix(in srgb, var(--error-bg-color) 12%, transparent);
                              color: var(--error-color); }
        .debugger-message { color: var(--error-color); }
        row.debugger-current-frame label.title { font-weight: bold; }
        .debugger-register { min-width: 0; }
        .debugger-canvas:focus-visible { outline: 2px solid color-mix(in srgb, var(--accent-color) 50%, transparent);
                                         outline-offset: -2px; }
        .debugger-tabs toggle { padding-left: 7px; padding-right: 7px; }
        """
        guard css != installedFor else { return }
        installedFor = css
        if provider == nil {
            provider = gtk_css_provider_new()
            gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider!),
                                                       guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
            // Again when the font setting changes, and redraw.
            GObjectRef(adw_style_manager_get_default()).onChange("monospace-font-name") {
                install()
                NotificationCenter.default.post(name: themeChanged, object: nil)
            }
            for property in ["dark", "accent-color", "high-contrast"] {
                GObjectRef(adw_style_manager_get_default()).onChange(property) {
                    NotificationCenter.default.post(name: themeChanged, object: nil)
                }
            }
        }
        gtk_css_provider_load_from_string(provider, css)
    }

    /// Posted when drawn views should redraw (light or dark, the accent, the
    /// font).
    static let themeChanged = Notification.Name("MacBeebDebuggerThemeChanged")
}

// MARK: Small pieces

/// A row of a boxed list holding any widget (GtkListBoxRow), not
/// activatable unless asked.
@MainActor
func ListRow(_ child: Widget, activatable: Bool = false) -> Widget {
    let row = gtk_list_box_row_new()!
    gtk_list_box_row_set_child(cast(row), child.widget)
    gtk_list_box_row_set_activatable(cast(row), activatable ? 1 : 0)
    return Widget(row)
}

/// What a list shows when it's empty: a few words, dimmed and centred (the
/// Mac's overlays).
@MainActor
func EmptyState(_ text: String) -> Label {
    let label = Label(text, style: "dim-label")
    label.wrap().centred().margin(24).align(vertical: GTK_ALIGN_CENTER).expand()
    return label
}

/// A pane's header: its title, then its controls (the Mac's HStack of a
/// headline and buttons over a Divider).
@MainActor
func PaneHeader(_ title: String, @WidgetList _ controls: () -> [Widget]) -> Widget {
    let box = Box(.horizontal, spacing: 6)
    box.append(Label(title, style: "heading"))
    for control in controls() { box.append(control) }
    return box.margin(top: 6, bottom: 6, start: 12, end: 8).style("debugger-pane-header")
}

/// A flexible space in a row (the shared Spacer expands both ways, and
/// would stretch a header bar's row of controls downwards).
@MainActor
func HSpacer() -> Widget {
    Widget(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)).expand(horizontal: true, vertical: false)
}

/// A row titled with plain text (libadwaita reads a row's title as markup
/// by default, and an address's & is markup's).
@MainActor
func PlainActionRow(_ title: String, subtitle: String? = nil) -> ActionRow {
    let row = ActionRow("")
    row.title = title
    if let subtitle { row.subtitle = subtitle }
    return row
}

/// An entry row titled with plain text.
@MainActor
func PlainEntryRow(_ title: String) -> EntryRow {
    let row = EntryRow("")
    adw_preferences_row_set_use_markup(cast(row.widget), 0)
    adw_preferences_row_set_title(cast(row.widget), title)
    return row
}

/// An icon-only button, with its tooltip and accessible name.
@MainActor
func IconButton(_ icon: String, _ help: String, label: String? = nil, _ action: @escaping @MainActor () -> Void) -> Button {
    let button = Button(icon: icon, action)
    button.tooltip(help).accessibleLabel(label ?? help)
    return button.style("flat")
}

/// The number in a register or byte field: hex, with or without its &
/// (or $, or 0x), as the Mac's fields take it.
func parseHex(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let prefixed = ["&", "$", "0x", "0X"].contains { trimmed.hasPrefix($0) }
    return parseNumber(prefixed ? trimmed : "&" + trimmed)
}
