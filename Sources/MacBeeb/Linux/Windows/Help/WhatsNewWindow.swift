import CGtk
import Foundation

/// Help > What’s New in MacBeeb, also opened on the first launch after an
/// update: the release notes, newest first, with those since the last
/// version the user ran marked New. (The Mac's is WhatsNewView.)
@MainActor
enum WhatsNewWindow {
    static func show() {
        Windows.show("whats-new") { make() }
    }

    /// The releases: as the shared code found them, or (installed, where
    /// it looks in the app's bundle) WHATSNEW.md in share/macbeeb.
    private static var releases: [WhatsNew.Release] {
        if !WhatsNew.releases.isEmpty { return WhatsNew.releases }
        return AppResources.file(installed: "WHATSNEW.md", source: "WHATSNEW.md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map(WhatsNew.parse) ?? []
    }

    private static func make() -> Window {
        let window = Window(title: "What’s New in MacBeeb", width: 560, height: 640)
        window.minimumSize(width: 360, height: 360)
        let document = HelpDocument()

        let header = Box(.horizontal, spacing: 14) {
            Icon(App.id, size: 56)
            Box(.vertical, spacing: 2) {
                Label("What’s New in MacBeeb", style: "title-2").wrap()
                Label("Version \(WhatsNew.currentVersion)", style: "dim-label", "numeric")
            }
            .align(vertical: GTK_ALIGN_CENTER)
        }

        let notes = Box(.vertical, spacing: 26)
        notes.append(header)
        let releases = releases
        if releases.isEmpty {
            notes.append(Label("There are no release notes in this build.", style: "dim-label").wrap())
        }
        for release in releases {
            notes.append(section(release, document))
        }
        let clamp = Clamp(notes.margin(top: 6, bottom: 24, start: 24, end: 24), maximum: 680)
        let scroller = HelpDocument.scroller(clamp)

        let link = Label(markup: "<a href=\"\(AboutDialog.repository.appendingPathComponent("releases").absoluteString)\">All releases on GitHub</a>")
        link.onLink { uri in
            if let url = URL(string: uri) { Platform.open(url) }
            return true
        }
        let done = Button("_Continue") { window.close() }.style("suggested-action", "pill")
        let footer = Box(.horizontal, spacing: 12) {
            link.align(vertical: GTK_ALIGN_CENTER)
            Spacer()
            done
        }
        .margin(horizontal: 18, vertical: 12)

        window.content = ToolbarView(content: scroller)
            .top(HeaderBar(title: Label("")).style("flat"))
            .bottom(footer)
        done.isDefault(in: window)
        App.addStandardShortcuts(to: window)
        window.shortcut("Escape", action: "window.close")
        window.keep(document)
        // Continue has the focus, as the default (not the notes' first
        // line, which focus would select).
        gtk_window_set_focus(window.window, done.widget)
        return window
    }

    private static func section(_ release: WhatsNew.Release, _ document: HelpDocument) -> Widget {
        let title = Box(.horizontal, spacing: 8) {
            Label(release.version, style: "title-4")
        }
        if let date = release.date {
            title.append(Label(date, style: "dim-label").align(vertical: GTK_ALIGN_BASELINE_CENTER))
        }
        if WhatsNew.isNew(release, since: WhatsNew.previousVersion) {
            title.append(Label("NEW", style: "help-badge").align(vertical: GTK_ALIGN_CENTER)
                .accessibleLabel("New"))
        }
        let section = Box(.vertical, spacing: 10)
        section.append(title)
        var blocks: [HelpMarkdown.Block] = release.intro.map { .paragraph($0) }
        if !release.items.isEmpty {
            blocks.append(.list(ordered: false, start: 1, items: release.items.map { [.paragraph($0)] }))
        }
        section.append(document.view(blocks))
        return section
    }
}

/// Help > Credits: the work MacBeeb is built on and includes, from
/// CREDITS.md (installed in share/macbeeb; run from the source tree, the
/// repository's). The Mac's is CreditsWindow.
@MainActor
enum CreditsWindow {
    static func show() {
        Windows.show("credits") { make() }
    }

    static var text: String? {
        AppResources.file(installed: "CREDITS.md", source: "CREDITS.md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func make() -> Window {
        let window = Window(title: "Credits", width: 720, height: 760)
        window.minimumSize(width: 360, height: 360)
        let content: Widget
        if let text {
            let document = HelpDocument()
            let header = Box(.horizontal, spacing: 16) {
                Icon(App.id, size: 64)
                Box(.vertical, spacing: 2) {
                    Label("MacBeeb", style: "title-1")
                    Label("With thanks to everyone whose work it builds on", style: "dim-label").wrap()
                }
                .align(vertical: GTK_ALIGN_CENTER)
            }
            // The document's own title is the header above.
            let blocks = HelpMarkdown.parse(text).filter {
                if case .heading(1, _) = $0 { false } else { true }
            }
            let body = Box(.vertical, spacing: 20) {
                header
                document.view(blocks)
            }
            let clamp = Clamp(body.margin(top: 12, bottom: 40, start: 24, end: 24), maximum: 760)
            adw_clamp_set_tightening_threshold(cast(clamp.widget), 600)
            content = HelpDocument.scroller(clamp)
            window.keep(document)
        } else {
            content = StatusPage(icon: "emote-love-symbolic", title: "No credits",
                                 description: "The credits weren’t found in the app.")
        }
        window.content = ToolbarView(content: content).top(HeaderBar())
        App.addStandardShortcuts(to: window)
        return window
    }
}
