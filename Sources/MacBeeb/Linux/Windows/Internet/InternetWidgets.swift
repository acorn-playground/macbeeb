import BeebNetwork
import CGtk
import Foundation

// What the Internet Econet windows share: their styles (libadwaita's own
// colours, so light and dark both work), a station number badge, the
// connection badge, and buttons that show a spinner while they work.

@MainActor
enum InternetStyles {
    private static var installed = false

    /// Installs the styles, once.
    static func install() {
        guard !installed else { return }
        installed = true
        let css = """
        .internet-globe { color: var(--accent-teal); }
        label.internet-station-badge {
            background-color: var(--accent-bg-color);
            color: var(--accent-fg-color);
            border-radius: 6px;
            padding: 2px 4px;
            min-width: 24px;
            font-weight: 700;
            font-size: 0.9em;
            font-feature-settings: "tnum";
        }
        .internet-dot {
            min-width: 8px;
            min-height: 8px;
            border-radius: 4px;
            background-color: color-mix(in srgb, currentColor 35%, transparent);
        }
        .internet-dot.online { background-color: var(--success-color); }
        .internet-dot.waiting { background-color: var(--warning-color); }
        .internet-dot.ended { background-color: var(--error-color); }
        .internet-conflicts {
            background-color: color-mix(in srgb, var(--warning-bg-color) 14%, var(--window-bg-color));
            border: 1px solid color-mix(in srgb, var(--warning-bg-color) 40%, transparent);
            border-radius: 12px;
            padding: 12px;
        }
        row.internet-code .subtitle {
            font-family: var(--monospace-font-family);
            font-size: 1.35em;
            font-weight: 700;
        }
        row.internet-subtitle-warning .subtitle { color: var(--warning-color); opacity: 1; }
        row.internet-title-warning .title { color: var(--warning-color); }
        .internet-dump { font-size: 0.85em; }
        """
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}

/// A station's number, on the accent colour (the Mac's StationBadge).
@MainActor
func InternetStationBadge(_ number: Int?) -> Label {
    InternetStyles.install()
    let label = Label(number.map(String.init) ?? "–", style: "internet-station-badge")
    label.centred().align(vertical: GTK_ALIGN_CENTER)
    label.accessibleLabel(number.map { "Station \($0)" } ?? "No station number")
    return label
}

/// A globe, as the Mac's sheets have (GNOME's icons have none), drawn in
/// the theme's teal.
@MainActor
func InternetGlobe(size: Int32) -> Widget {
    InternetStyles.install()
    let area = DrawingArea(width: size, height: size) { _, _, _ in }
    area.style("internet-globe").align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
    area.setDraw { cairo, width, height in
        let side = min(width, height)
        let line = max(1.5, side / 18)
        let radius = side / 2 - line
        let x = width / 2, y = height / 2
        cairo.foreground(of: area)
        cairo.circle(x, y, radius: radius)
        cairo.stroke(width: line)
        // Meridians: the middle one, and an ellipse either side.
        cairo.move(x, y - radius)
        cairo.line(x, y + radius)
        cairo.stroke(width: line)
        cairo.save()
        cairo.translate(x, y)
        cairo.scale(0.48, 1)
        cairo.circle(0, 0, radius: radius)
        cairo.restore()
        cairo.stroke(width: line)
        // The equator, and a parallel either side.
        cairo.move(x - radius, y)
        cairo.line(x + radius, y)
        for offset in [-radius * 0.52, radius * 0.52] {
            let half = (radius * radius - offset * offset).squareRoot()
            cairo.move(x - half, y + offset)
            cairo.line(x + half, y + offset)
        }
        cairo.stroke(width: line)
    }
    area.accessibleLabel("Internet")
    return area
}

/// A coloured dot (online, waiting, ended, or none of those: dim).
@MainActor
final class InternetStatusDot {
    let widget = Widget(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))

    enum Tone: String, CaseIterable {
        case online, waiting, ended, off
    }

    init(_ tone: Tone = .off) {
        InternetStyles.install()
        widget.style("internet-dot").align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
        set(tone)
    }

    func set(_ tone: Tone) {
        for other in Tone.allCases where other != .off {
            widget.setStyle(other.rawValue, other == tone)
        }
    }
}

/// Connected, reconnecting, or not.
@MainActor
enum ConnectionBadge {
    /// What a state's called, and its dot's tone.
    static func describe(_ state: RoomConnection.State?) -> (text: String, tone: InternetStatusDot.Tone) {
        switch state {
        case .connected: ("Connected", .online)
        case .connecting, nil: ("Connecting…", .waiting)
        case .reconnecting: ("Reconnecting…", .waiting)
        case .ended: ("Disconnected", .ended)
        case .stopped: ("Not connected", .off)
        }
    }

    /// A badge following `state` as it changes.
    static func make(_ state: @escaping @MainActor () -> RoomConnection.State?) -> Widget {
        let dot = InternetStatusDot()
        let label = Label()
        let badge = Box(.horizontal, spacing: 6) {
            dot.widget
            label
        }
        badge.align(vertical: GTK_ALIGN_CENTER)
        badge.keep(dot)
        badge.track {
            let (text, tone) = describe(state())
            label.text = text
            dot.set(tone)
            badge.accessibleLabel(text)
        }
        return badge
    }
}

/// A button whose label gives way to a spinner while it's busy.
@MainActor
final class InternetBusyButton {
    let button: Button
    private let stack = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    private let label: Label

    init(_ title: String, _ action: @escaping @MainActor () -> Void) {
        label = Label(title).centred()
        gtk_label_set_use_underline(cast(label.widget), 1)
        stack.add(label, name: "label")
        stack.add(Spinner().size(width: 16, height: 16).align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER),
                  name: "busy")
        button = Button(child: stack, action)
        gtk_label_set_mnemonic_widget(cast(label.widget), button.widget)
        button.accessibleLabel(title.replacingOccurrences(of: "_", with: ""))
        button.keep(self)
    }

    var isBusy: Bool = false {
        didSet {
            stack.visible = isBusy ? "busy" : "label"
        }
    }
}

/// Saves JSON: GTK's file dialog, with a filter for it.
@MainActor
enum InternetJSONSave {
    typealias Done = @MainActor (OpaquePointer, OpaquePointer) -> Void

    static func choose(suggestedName: String, title: String, _ completion: @escaping @MainActor (URL?) -> Void) {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_modal(dialog, 1)
        gtk_file_dialog_set_initial_name(dialog, suggestedName)
        let store = g_list_store_new(gtk_file_filter_get_type())!
        let json = gtk_file_filter_new()!
        gtk_file_filter_set_name(json, "JSON")
        gtk_file_filter_add_suffix(json, "json")
        gtk_file_filter_add_mime_type(json, "application/json")
        g_list_store_append(store, gpointer(json))
        gtk_file_dialog_set_filters(dialog, store)
        gtk_file_dialog_set_default_filter(dialog, json)
        g_object_unref(gpointer(json))
        g_object_unref(gpointer(store))
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer { if let error { g_error_free(error) } }
            let file = gtk_file_dialog_save_finish(dialog, result, &error)
            let url = URL(gFile: file)
            if let file { g_object_unref(gpointer(file)) }
            g_object_unref(gpointer(dialog))
            completion(url)
        }
        let parent = Application.shared.activeWindow.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
        gtk_file_dialog_save(dialog, parent, nil, internetFileDialogFinished, Boxed<Done>(done).retained)
    }
}

/// (Outside the main actor's types, as C callbacks must be.)
private func internetFileDialogFinished(_ source: UnsafeMutablePointer<GObject>?, _ result: OpaquePointer?, _ data: gpointer?) {
    guard let source, let result else { return }
    let dialog = UInt(bitPattern: source), outcome = UInt(bitPattern: result), box = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        Boxed<InternetJSONSave.Done>.from(UnsafeMutableRawPointer(bitPattern: box))(OpaquePointer(bitPattern: dialog)!,
                                                                                 OpaquePointer(bitPattern: outcome)!)
    }
    AnyBox.release(data)
}

extension EntryRow {
    /// Text shown in the field while it's empty and being typed in (the
    /// row's title stands in for it otherwise).
    @discardableResult
    func placeholderText(_ text: String) -> Self {
        if let delegate = gtk_editable_get_delegate(OpaquePointer(widget)) {
            gtk_text_set_placeholder_text(cast(delegate), text)
        }
        return self
    }

    /// Return presses the window's default button.
    @discardableResult
    func returnActivatesDefault() -> Self {
        adw_entry_row_set_activates_default(cast(widget), 1)
        return self
    }

    /// Return pressed in it.
    @discardableResult
    func onReturn(_ body: @escaping @MainActor () -> Void) -> Self {
        object.on("entry-activated", body)
        return self
    }

    @discardableResult
    func monospaceText() -> Self {
        if let delegate = gtk_editable_get_delegate(OpaquePointer(widget)) {
            gtk_widget_add_css_class(cast(delegate), "monospace")
        }
        return self
    }
}
