import BeebCore
import BeebLibrary
import CGtk
import Foundation

/// The details of one of My Games being added or edited: what it's
/// called, its disc and cover, and how to play it. Discs and pictures can
/// be dropped on it. (The Mac's GameDetailsSheet.)
@MainActor
final class GameDetailsDialog {
    private(set) var draft: GameDraft
    private let classics = ClassicsLibrary.shared
    private var dialog: Dialog?
    private var closed = false
    private var saving = false
    private var yearText = ""
    private var command = ""
    private var startChoice = StartChoice.boot
    private var shownCover: URL?
    private var coverShown = false

    enum StartChoice: Hashable {
        case boot, type, insertOnly
    }

    // The controls that change as the draft does.
    private let titleRow = EntryRow("Title")
    private let saveButton: Button
    private let cover = ShelfCover(width: 100, height: 140)
    private let coverStack = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    private let coverWell: Button
    private let discGroup = PreferencesGroup(title: "Disc")
    private let discRow = ActionRow("")
    private let discIcon = Icon("media-optical-symbolic", size: 16)
    private let discButton = Button("")
    private let models = BBCMicro.Model.allCases
    private var coprocessors: [BBCMicro.Coprocessor] = []
    private let modelRow: ComboRow
    private let coprocessorRow = ComboRow("Second processor", items: ["None"])
    private var startChecks: [StartChoice: CheckButton] = [:]
    private let commandRow = EntryRow("Command")

    init(draft: GameDraft) {
        self.draft = draft
        saveButton = Button(draft.isNew ? "_Add Game" : "_Save")
        coverWell = Button(child: coverStack)
        modelRow = ComboRow("Model", items: models.map(\.displayName),
                            selected: models.firstIndex(of: draft.game.model) ?? 0)
        yearText = draft.game.year.map(String.init) ?? ""
        switch draft.game.start {
        case .boot: startChoice = .boot
        case .insertOnly: startChoice = .insertOnly
        case .type(let text):
            startChoice = .type
            command = text
        }
    }

    // MARK: Showing

    func present(over window: Window) {
        let content = build()
        let header = HeaderBar().showsWindowButtons(start: false, end: false)
        let cancel = Button("_Cancel") { [weak self] in self?.dialog?.close() }
        saveButton.style("suggested-action")
        saveButton.onClicked { [weak self] in self?.save() }
        header.start(cancel).end(saveButton)
        let toolbar = ToolbarView(content: content).top(header)
        // (Self-tests may make it taller, to see it all.)
        let height = LaunchScreen.isSelfTest ? max(UserDefaults.standard.integer(forKey: "MacBeebLibraryDialogHeight"), 680) : 680
        let dialog = Dialog(title: draft.isNew ? "Add a Game" : "Edit Game", content: toolbar, width: 540, height: Int32(height))
        self.dialog = dialog
        dialog.defaultWidget(saveButton)
        dialog.focus(titleRow)
        dialog.keep(self)
        dialog.onClosed { [weak self] in
            guard let self else { return }
            self.closed = true
            self.dialog = nil
            // Escape, or Cancel: the draft's dropped.
            if self.classics.drafts.contains(where: { $0.id == self.draft.id }) {
                self.classics.cancel(self.draft)
            }
        }
        // Discs and pictures dropped anywhere on it.
        let drop = DropTarget.files { [weak self] urls, _, _ in
            guard let self else { return false }
            self.coverWell.removeStyle("drop-hover")
            return self.take(urls)
        }
        drop.onHover { [coverWell] in coverWell.setStyle("drop-hover", $0) }
        toolbar.add(drop)
        refresh()
        dialog.present(over: window)
    }

    /// Its Add Game (or Save) button.
    var saveButtonWidget: Widget { saveButton }

    /// Closes it, keeping the draft (it's been saved, or it's gone).
    func close() {
        guard !closed, let dialog else { return }
        closed = true
        self.dialog = nil
        dialog.close()
    }

    // MARK: Building

    private func build() -> Widget {
        // The cover, and what it's called.
        let empty = Box(.vertical, spacing: 4) {
            Icon("image-x-generic-symbolic", size: 32)
            Label("Drop a cover", style: "caption").centred()
        }
        .align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
        .style("dim-label")
        coverStack.add(empty, name: "empty").add(cover.box, name: "cover")
        cover.box.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
        coverWell.style("cover-well")
            .size(width: 110, height: 150)
            .align(vertical: GTK_ALIGN_START)
            .tooltip("Drop a picture here, or click to choose one")
        coverWell.onClicked { [weak self] in self?.chooseCover() }

        titleRow.text = draft.game.title
        titleRow.object.set("activates-default", true)
        titleRow.onApplyless { [weak self] text in
            self?.draft.game.title = text
            self?.refresh()
        }
        let publisherRow = EntryRow("Publisher", text: draft.game.publisher ?? "") { [weak self] text in
            self?.draft.game.publisher = text.isEmpty ? nil : text
        }
        publisherRow.object.set("activates-default", true)
        let yearRow = EntryRow("Year", text: yearText) { [weak self] text in self?.yearText = text }
        yearRow.object.set("activates-default", true)
        let names = ListBox()
        names.style("boxed-list")
        names.append(titleRow)
        names.append(publisherRow)
        names.append(yearRow)
        names.expand(horizontal: true).align(vertical: GTK_ALIGN_START)
        let top = PreferencesGroup {
            Box(.horizontal, spacing: 16) {
                coverWell
                names
            }
        }

        // The disc.
        discRow.prefix(discIcon)
        discButton.align(vertical: GTK_ALIGN_CENTER)
        discButton.onClicked { [weak self] in self?.chooseDisc() }
        discRow.suffix(discButton)
        discGroup.add(discRow)

        // The machine.
        modelRow.object.onChange("selected") { [weak self] in
            guard let self, self.modelRow.selected >= 0 else { return }
            self.draft.game.model = self.models[self.modelRow.selected]
            if let coprocessor = self.draft.game.coprocessor, !coprocessor.fits(self.draft.game.model) {
                self.draft.game.coprocessor = nil
            }
            self.refreshCoprocessors()
        }
        coprocessorRow.object.onChange("selected") { [weak self] in
            guard let self, self.coprocessorRow.selected >= 0 else { return }
            let index = self.coprocessorRow.selected
            self.draft.game.coprocessor = index == 0 ? nil : self.coprocessors[index - 1]
        }
        refreshCoprocessors()
        let machine = PreferencesGroup(title: "Machine") {
            modelRow
            coprocessorRow
        }

        // Starting it.
        let starting = PreferencesGroup(title: "Starting")
        var first: CheckButton?
        for (choice, label) in [(StartChoice.boot, "Booting the disc (Shift-Break)"), (.type, "Typing a command"),
                                (.insertOnly, "Just putting the disc in")] {
            let check = CheckButton("", isOn: choice == startChoice) { [weak self] on in
                guard on, let self else { return }
                self.startChoice = choice
                self.refresh()
            }
            if let first { check.group(with: first) } else { first = check }
            startChecks[choice] = check
            let row = ActionRow(label).prefix(check).activates(check)
            starting.add(row)
        }
        commandRow.text = command
        commandRow.object.on("changed") { [weak self] in
            guard let self else { return }
            self.command = self.commandRow.text
        }
        commandRow.object.set("activates-default", true)
        if let text = gtk_editable_get_delegate(cast(commandRow.widget)) {
            // CHAIN "GAME", in the BBC's own type.
            gtk_text_set_placeholder_text(cast(text), "CHAIN \"GAME\"")
            gtk_widget_add_css_class(cast(text), "monospace")
        }
        starting.add(commandRow)

        // Notes.
        let notes = TextView(text: draft.game.notes ?? "", editable: true)
        notes.margins(10).style("notes-view")
        let placeholder = Label("Controls, tips, where it came from…", style: "dim-label")
            .align(horizontal: GTK_ALIGN_START, vertical: GTK_ALIGN_START)
            .margin(10)
            .canTarget(false)
        placeholder.isVisible = notes.text.isEmpty
        notes.onChanged { [weak self] text in
            placeholder.isVisible = text.isEmpty
            self?.draft.game.notes = text.isEmpty ? nil : text
        }
        notes.accessibleLabel("Notes")
        let notesScroller = ScrolledWindow(notes, horizontal: GTK_POLICY_NEVER)
            .minContentHeight(96)
            .maxContentHeight(160)
            .propagateNaturalHeight()
        notesScroller.style("card")
        let notesGroup = PreferencesGroup(title: "Notes") {
            Overlay(notesScroller) { placeholder }
        }

        let page = PreferencesPage {
            top
            discGroup
            machine
            starting
            notesGroup
        }
        return page
    }

    // MARK: State

    private func refresh() {
        saveButton.isEnabled = !draft.game.title.trimmingCharacters(in: .whitespaces).isEmpty && !saving
        if titleRow.text != draft.game.title { titleRow.text = draft.game.title }

        // The cover (read again only when it's another).
        if draft.shownCover != shownCover || !coverShown {
            shownCover = draft.shownCover
            coverShown = true
            if let url = shownCover, let picture = LibraryPicture(url: url, maxSize: 320) {
                cover.set(.image(picture))
                coverStack.visible = "cover"
                coverWell.accessibleLabel("Cover. Choose another picture.")
            } else {
                coverStack.visible = "empty"
                coverWell.accessibleLabel("No cover. Choose a cover picture.")
            }
        }

        // The disc.
        if let disc = draft.disc {
            discRow.title = disc.fileName
        } else if draft.existingDiscName != nil {
            discRow.title = "The game’s disc"
        } else {
            discRow.title = "No disc yet"
        }
        discIcon.opacity(draft.hasDisc ? 1 : 0.4)
        discButton.label = draft.hasDisc ? "Replace…" : "Choose…"
        discGroup.detail = draft.hasDisc ? "" : "You can add the disc later: drop it on the game."

        // Starting.
        for (choice, check) in startChecks { check.isOn = choice == startChoice }
        commandRow.isVisible = startChoice == .type
    }

    private func refreshCoprocessors() {
        let model = draft.game.model
        coprocessors = BBCMicro.Coprocessor.allCases.filter { $0.fits(model) }
        let selected = draft.game.coprocessor.flatMap { coprocessors.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        coprocessorRow.setItems(["None"] + coprocessors.map(\.displayName), selected: selected)
        coprocessorRow.isEnabled = model.hasTube
        if modelRow.selected != models.firstIndex(of: model) {
            modelRow.selected = models.firstIndex(of: model) ?? 0
        }
    }

    // MARK: Files

    private func chooseDisc() {
        Platform.chooseFiles(.discsOnly, multiple: false, message: nil) { [weak self] urls in
            guard let self, !self.closed else { return }
            _ = self.take(urls)
        }
    }

    private func chooseCover() {
        Platform.chooseFiles(.images, multiple: false, message: nil) { [weak self] urls in
            guard let self, !self.closed else { return }
            _ = self.take(urls)
        }
    }

    /// A disc image or picture dropped on (or chosen in) the dialog.
    private func take(_ urls: [URL]) -> Bool {
        let discURL = urls.first(where: MyGames.isDiscName)
        let coverURL = urls.first(where: MyGames.isCoverName)
        guard discURL != nil || coverURL != nil else { return false }
        if let coverURL {
            do {
                _ = try MyGames.checkCover(at: coverURL)
                draft.newCover = coverURL
            } catch {
                Platform.showError(error)
            }
        }
        if let discURL {
            do {
                let disc = try MyGames.readDisc(at: discURL)
                let hadDisc = draft.hasDisc
                draft.disc = disc
                // A cover-first game: its disc says more about it.
                if draft.isNew && !hadDisc {
                    if draft.game.title.isEmpty || draft.game.title == coverURL?.deletingPathExtension().lastPathComponent
                        || draft.game.title == draft.newCover?.deletingPathExtension().lastPathComponent {
                        draft.game.title = disc.suggestedTitle
                    }
                    (draft.game.model, draft.game.coprocessor) = disc.suggestedMachine
                    startChoice = disc.suggestedStart == .boot ? .boot : .insertOnly
                    refreshCoprocessors()
                }
            } catch {
                Platform.showError(error)
            }
        }
        refresh()
        return true
    }

    // MARK: Saving

    private func save() {
        guard saveButton.isEnabled else { return }
        draft.game.title = draft.game.title.trimmingCharacters(in: .whitespaces)
        draft.game.year = Int(yearText.trimmingCharacters(in: .whitespaces))
        draft.game.start = switch startChoice {
        case .boot: .boot
        case .insertOnly: .insertOnly
        case .type: .type(command)
        }
        saving = true
        refresh()
        let draft = draft
        Task {
            // (Saved, the draft's gone, and the library closes this.)
            _ = await classics.save(draft)
            saving = false
            if !closed { refresh() }
        }
    }
}

extension EntryRow {
    /// Calls `body` with the text as it changes.
    @discardableResult
    fileprivate func onApplyless(_ body: @escaping @MainActor (String) -> Void) -> Self {
        let editable = widget
        object.on("changed") { body(String(cString: gtk_editable_get_text(cast(editable)))) }
        return self
    }
}
