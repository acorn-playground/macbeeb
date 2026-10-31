import BeebNetwork
import CGtk
import Foundation

/// New Network: choose a template (or reopen a recent network). (The
/// Mac's NetworkStartView.)
@MainActor
enum NetworkStartWindow {
    static let key = "network-start"
    private static var previewed = false

    static func show() {
        NetworkStudioCommands.installObservers()
        // (A self-test's preview network, once.)
        if !previewed {
            previewed = true
            if NetworkStudioPreview.runIfRequested() { return }
        }
        NetworkStyles.install()
        Windows.show(key) { make() }
    }

    private static func close() {
        Windows.close(key)
    }

    private static func make() -> Window {
        let window = Window(title: "New Network", width: 880, height: 760)
        window.minimumSize(width: 360, height: 420)

        let title = Label("New Network", style: "title-1")
        let intro = Label("BBC Micros that share a network, each running for real. Start from one of these, then add, arrange and use the machines.",
                          style: "dim-label").wrap()
        let templates = FlowBox(spacing: 14, minColumns: 1, maxColumns: 3)
        for template in NetworkTemplate.allCases {
            let card = templateCard(template)
            templates.append(card)
            // (The card's the button: one stop each for the keyboard.)
            if let child = gtk_widget_get_parent(card.widget) { gtk_widget_set_focusable(child, 0) }
        }
        let recentList = ListBox().style("boxed-list")
        let recentBox = Box(.vertical, spacing: 6) {
            Label("Recent", style: "heading")
            recentList
        }
        recentBox.track { [recentList, recentBox] in
            let urls = Array(RecentNetworks.shared.existing.prefix(5))
            recentList.removeAll()
            recentBox.isVisible = !urls.isEmpty
            for url in urls {
                let row = ActionRow(url.deletingPathExtension().lastPathComponent, subtitle: url.deletingLastPathComponent().path,
                                    icon: "network-workgroup-symbolic")
                row.suffix(Icon("go-next-symbolic").style("dim-label"))
                row.onActivated {
                    NetworkStudioCommands.open(url)
                    close()
                }
                row.tooltip(url.path)
                recentList.append(row)
            }
        }
        let open = Button("_Open Network…") { NetworkStudioCommands.chooseAndOpen { close() } }.style("pill")
        let footer = Box(.horizontal, spacing: 12) {
            open
            Label("New networks are saved as you work; closing one asks whether to keep it, and where.", style: "caption", "dim-label")
                .wrap().expand(horizontal: true)
        }
        let body = Box(.vertical, spacing: 20) {
            Box(.vertical, spacing: 4) { title; intro }
            templates
            recentBox
            footer
        }
        body.margin(top: 12, bottom: 28, start: 28, end: 28)
        let header = HeaderBar(title: Bin())
        window.content = ToolbarView(content: ScrolledWindow(Clamp(body, maximum: 820), horizontal: GTK_POLICY_NEVER)).top(header)
        App.addStandardShortcuts(to: window)
        window.shortcut("<Alt>w", action: "window.close")
        window.shortcut("<Control>o", action: "app.open-network")
        return window
    }

    private static func templateCard(_ template: NetworkTemplate) -> Widget {
        let icon = Icon(icon(for: template), size: 28).style("template-icon").align(horizontal: GTK_ALIGN_START)
        icon.size(height: 34)
        let summary = Label(template.summary, style: "dim-label").wrap().maxWidthChars(18).widthChars(12)
        let content = Box(.vertical, spacing: 10) {
            icon
            Label(template.title, style: "heading").wrap().widthChars(12).maxWidthChars(18)
            summary
        }
        content.align(vertical: GTK_ALIGN_START)
        let button = Button(child: content) { create(template) }
        button.style("card", "template-card").size(height: 150)
        button.accessibleLabel("\(template.title): \(template.summary)")
        return button
    }

    /// The template's picture, from GNOME's icons (the Mac's are SF Symbols).
    static func icon(for template: NetworkTemplate) -> String {
        switch template {
        case .econetDemo: "starred-symbolic"
        case .econetTimes: "x-office-document-symbolic"
        case .eliteOverEconet: "airplane-mode-symbolic"
        case .distributedMandelbrot: "view-app-grid-symbolic"
        case .mandelbrotInColour: "applications-graphics-symbolic"
        case .twoBBCs: "video-joined-displays-symbolic"
        case .schoolClassroom: "system-users-symbolic"
        case .bbcAndMaster: "view-dual-symbolic"
        case .empty: "document-new-symbolic"
        }
    }

    private static func create(_ template: NetworkTemplate) {
        do {
            let url = try NetworkStudioCommands.createDraft(template)
            NetworkStudioCommands.open(url)
            close()
        } catch {
            AlertDialog("Can’t make the network", body: error.localizedDescription)
                .response("ok", "_OK", .suggested)
                .defaults(default: "ok", close: "ok")
                .present(over: Windows.existing(key))
        }
    }
}
