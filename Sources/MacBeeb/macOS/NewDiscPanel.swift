import AppKit
import BeebCore
import UniformTypeIdentifiers

/// File > New Disc…: a save panel with the disc's format, its title, and
/// which drive to put it in.
@MainActor
final class NewDiscPanel: NSObject {
    struct Choice {
        var url: URL
        var kind: BlankDisc
        var title: String
        /// nil: don't put it in a drive.
        var drive: Int?
    }

    private static let formatDefaultsKey = "MacBeebNewDiscFormat"

    private let panel = NSSavePanel()
    private let formatPopUp = NSPopUpButton()
    private let titleField = NSTextField()
    private let drivePopUp = NSPopUpButton()

    /// `model` picks the first format offered (ADFS for the Compact,
    /// otherwise DFS) until the user's chosen one; the drive offered is the
    /// first empty one.
    /// Runs the panel (modally: `completion` is called before this
    /// returns), with nil if it's cancelled. Linux's panel has the same.
    func present(_ completion: (Choice?) -> Void) {
        completion(run())
    }

    init(model: BBCMicro.Model, emptyDrives: [Int]) {
        super.init()
        for kind in BlankDisc.allCases {
            formatPopUp.addItem(withTitle: kind.name)
            formatPopUp.lastItem?.representedObject = kind.rawValue
        }
        let saved = UserDefaults.standard.string(forKey: Self.formatDefaultsKey).flatMap(BlankDisc.init(rawValue:))
        let kind = saved ?? (model == .masterCompact ? .adfsL : .dfs80)
        formatPopUp.selectItem(at: BlankDisc.allCases.firstIndex(of: kind) ?? 0)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)

        titleField.placeholderString = "The file’s name"
        titleField.delegate = self

        drivePopUp.addItems(withTitles: ["Drive 0", "Drive 1", "Neither (Just Save It)"])
        drivePopUp.selectItem(at: emptyDrives.first ?? 1)

        let grid = NSGridView(views: [
            [label("Format:"), formatPopUp],
            [label("Title:"), titleField],
            [label("Put in:"), drivePopUp],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        titleField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        grid.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView()
        accessory.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: accessory.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: accessory.leadingAnchor, constant: 20),
        ])

        panel.title = "New Disc"
        panel.message = "A blank disc, formatted and ready to save to."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Save As:"
        panel.nameFieldStringValue = "Blank Disc"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.accessoryView = accessory
        formatChanged()
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private var kind: BlankDisc {
        (formatPopUp.selectedItem?.representedObject as? String).flatMap(BlankDisc.init(rawValue:)) ?? .dfs80
    }

    @objc private func formatChanged() {
        let kind = kind
        panel.allowedContentTypes = [UTType(filenameExtension: kind.format.rawValue) ?? .data]
        // Keep the title within what the format holds.
        titleField.stringValue = String(titleField.stringValue.prefix(kind.maxTitleLength))
    }

    /// Runs the panel; nil if cancelled.
    func run() -> Choice? {
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let kind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: Self.formatDefaultsKey)
        var title = titleField.stringValue
        if title.isEmpty {
            title = url.deletingPathExtension().lastPathComponent
        }
        let drive = drivePopUp.indexOfSelectedItem
        return Choice(url: url, kind: kind, title: title, drive: drive < 2 ? drive : nil)
    }
}

extension NewDiscPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        let limit = kind.maxTitleLength
        if titleField.stringValue.count > limit {
            titleField.stringValue = String(titleField.stringValue.prefix(limit))
            NSSound.beep()
        }
    }
}
