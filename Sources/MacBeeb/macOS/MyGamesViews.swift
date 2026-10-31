import AppKit
import BeebCore
import BeebLibrary
import SwiftUI
import UniformTypeIdentifiers

// My Games: the user's own games on the bookshelf, from disc images and
// cover pictures dragged in (either first, or both at once).

/// The details of a game being added or edited: what it's called, its
/// disc and cover, and how to play it.
struct GameDetailsSheet: View {
    @State var draft: GameDraft
    @State private var classics = ClassicsLibrary.shared
    @State private var saving = false
    @State private var yearText = ""
    @State private var command = ""
    @State private var startChoice = StartChoice.boot
    @Environment(\.dismiss) private var dismiss

    enum StartChoice: Hashable {
        case boot, type, insertOnly
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        coverWell
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Title", text: $draft.game.title, prompt: Text("Required"))
                            TextField("Publisher", text: optional(\.publisher), prompt: Text("Optional"))
                            TextField("Year", text: $yearText, prompt: Text("Optional"))
                        }
                    }
                }
                Section("Disc") {
                    discRow
                }
                Section("Machine") {
                    Picker("Model", selection: $draft.game.model) {
                        ForEach(BBCMicro.Model.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    Picker("Second processor", selection: $draft.game.coprocessor) {
                        Text("None").tag(BBCMicro.Coprocessor?.none)
                        ForEach(BBCMicro.Coprocessor.allCases, id: \.self) { coprocessor in
                            Text(coprocessor.displayName).tag(BBCMicro.Coprocessor?.some(coprocessor))
                                .disabled(!coprocessor.fits(draft.game.model))
                        }
                    }
                    .disabled(!draft.game.model.hasTube)
                }
                Section("Starting") {
                    Picker("Start by", selection: $startChoice) {
                        Text("Booting the disc (Shift-Break)").tag(StartChoice.boot)
                        Text("Typing a command").tag(StartChoice.type)
                        Text("Just putting the disc in").tag(StartChoice.insertOnly)
                    }
                    .pickerStyle(.radioGroup)
                    if startChoice == .type {
                        TextField("Command", text: $command, prompt: Text("CHAIN \"GAME\""))
                            .font(.system(.body, design: .monospaced))
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: optional(\.notes), prompt: Text("Controls, tips, where it came from…"),
                              axis: .vertical)
                        .lineLimit(2...5)
                        .labelsHidden()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !draft.hasDisc {
                    Text("You can add the disc later: drop it on the game.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    classics.cancel(draft)
                }
                .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Game" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.game.title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            yearText = draft.game.year.map(String.init) ?? ""
            switch draft.game.start {
            case .boot: startChoice = .boot
            case .insertOnly: startChoice = .insertOnly
            case .type(let text):
                startChoice = .type
                command = text
            }
        }
        .onChange(of: draft.game.model) {
            if let coprocessor = draft.game.coprocessor, !coprocessor.fits(draft.game.model) {
                draft.game.coprocessor = nil
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            _ = take(urls)
        }
    }

    // MARK: Files

    private var coverWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(.tertiary)
            if let url = draft.shownCover, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.title)
                    Text("Drop a cover")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 110, height: 150)
        .contentShape(Rectangle())
        .onTapGesture { chooseCover() }
        .help("Drop a picture here, or click to choose one")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(draft.shownCover == nil ? "No cover. Choose a cover picture." : "Cover. Choose another picture.")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var discRow: some View {
        HStack {
            Image(systemName: draft.hasDisc ? "opticaldisc" : "opticaldisc.fill")
                .foregroundStyle(draft.hasDisc ? .primary : .tertiary)
            if let disc = draft.disc {
                Text(disc.fileName)
            } else if draft.existingDiscName != nil {
                Text("The game’s disc")
            } else {
                Text("No disc yet").foregroundStyle(.secondary)
            }
            Spacer()
            Button(draft.hasDisc ? "Replace…" : "Choose…") { chooseDisc() }
        }
    }

    private func chooseDisc() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MachineController.discTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = take([url])
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = take([url])
    }

    /// A disc image or picture dropped on (or chosen in) the sheet.
    private func take(_ urls: [URL]) -> Bool {
        let discURL = urls.first(where: MyGames.isDiscName)
        let coverURL = urls.first(where: MyGames.isCoverName)
        guard discURL != nil || coverURL != nil else { return false }
        if let coverURL {
            do {
                _ = try MyGames.checkCover(at: coverURL)
                draft.newCover = coverURL
            } catch {
                NSAlert(error: error).runModal()
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
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        return true
    }

    private func optional(_ keyPath: WritableKeyPath<PersonalGame, String?>) -> Binding<String> {
        Binding(get: { draft.game[keyPath: keyPath] ?? "" },
                set: { draft.game[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        draft.game.title = draft.game.title.trimmingCharacters(in: .whitespaces)
        draft.game.year = Int(yearText.trimmingCharacters(in: .whitespaces))
        draft.game.start = switch startChoice {
        case .boot: .boot
        case .insertOnly: .insertOnly
        case .type: .type(command)
        }
        saving = true
        let draft = draft
        Task {
            _ = await classics.save(draft)
            saving = false
        }
    }
}

/// One of My Games on the shelf. Dropping a disc or picture on it gives it
/// that disc or cover.
struct PersonalTile: View {
    let game: PersonalGame
    let selected: Bool
    @State private var classics = ClassicsLibrary.shared
    @State private var targeted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            PersonalCover(game: game)
                .frame(height: 210, alignment: .bottom)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
            VStack(spacing: 2) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(1)
                Group {
                    if game.discFile == nil {
                        Label("No disc yet: drop one here", systemImage: "opticaldisc")
                            .foregroundStyle(.secondary)
                    } else if let latest = classics.latestSnapshots[game.id] {
                        ResumeLink(snapshot: latest, title: game.title)
                    } else {
                        Label("Ready to play", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            classics.attach(urls, to: game)
        } isTargeted: { targeted = $0 }
        .help(game.discFile == nil ? "\(game.title): drop its disc image here" : "\(game.title): drop a picture here for its cover")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(game.title), my game. \(game.discFile == nil ? "No disc yet." : "Ready to play.")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if let latest = classics.latestSnapshots[game.id] {
                Button("Resume") {
                    Player.restore(latest, title: game.title) { openWindow(id: MachineWindow.windowID) }
                }
            }
        }
    }

    private var background: AnyShapeStyle {
        if targeted { return AnyShapeStyle(Color.accentColor.opacity(0.3)) }
        return selected ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear)
    }
}

/// A game's own cover, or its title on a plain cover until it has one.
struct PersonalCover: View {
    let game: PersonalGame
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .coverPop()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.24), Color(red: 0.05, green: 0.07, blue: 0.12)],
                                             startPoint: .top, endPoint: .bottom))
                    VStack(spacing: 8) {
                        Text(game.title.uppercased())
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.cyan)
                        Text("Drop a cover here")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(10)
                }
                .aspectRatio(0.7, contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
        .task(id: game.coverFile) {
            guard let url = ClassicsLibrary.shared.myGames.coverURL(game) else {
                image = nil
                return
            }
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

/// The empty book at the end of My Games: drop discs and pictures on it, or
/// click it to choose them.
struct AddGameTile: View {
    @State private var classics = ClassicsLibrary.shared
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.6))
                VStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.largeTitle)
                    Text("Drop disc images or cover pictures here")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(12)
            }
            .aspectRatio(0.7, contentMode: .fit)
            .frame(height: 210)
            Text("Add a Game")
                .font(.headline)
            Text(" ").font(.caption)
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture { classics.chooseFiles() }
        .dropDestination(for: URL.self) { urls, _ in
            let wanted = urls.filter { MyGames.isDiscName($0) || MyGames.isCoverName($0) }
            classics.addFiles(wanted)
            return !wanted.isEmpty
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add a game: choose disc images and cover pictures")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { classics.chooseFiles() }
    }
}

/// One of My Games in the details panel.
struct PersonalGameDetail: View {
    let game: PersonalGame
    let openMachine: () -> Void
    @State private var classics = ClassicsLibrary.shared
    @State private var snapshots: [SnapshotManifest] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PersonalCover(game: game)
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .dropDestination(for: URL.self) { urls, _ in _ = classics.attach(urls, to: game) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.title2.weight(.semibold))
                    let byline = [game.publisher, game.year.map(String.init)].compactMap { $0 }.joined(separator: ", ")
                    if !byline.isEmpty {
                        Text(byline).foregroundStyle(.secondary)
                    }
                    Text("My game").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                if game.discFile != nil {
                    Button {
                        Player.play(game, openMachine: openMachine)
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    if let latest = snapshots.first {
                        ResumeButton(snapshot: latest, title: game.title, openMachine: openMachine)
                    }
                } else {
                    Text("Add the game’s disc image to play it: drop it on the game, or choose it.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        classics.chooseDisc(for: game)
                    } label: {
                        Text("Choose Disc…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                HStack {
                    Button("Edit…") { classics.edit(game) }
                    if game.discFile != nil {
                        Button("Replace Disc…") { classics.chooseDisc(for: game) }
                    }
                    Button(game.coverFile == nil ? "Add Cover…" : "Change Cover…") { classics.chooseCover(for: game) }
                }
                .buttonStyle(.link)
                HStack {
                    if let url = classics.myGames.discURL(game) {
                        Button("Reveal Disc") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Remove…") { classics.remove(game) }
                }
                .buttonStyle(.link)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Plays on").foregroundStyle(.secondary)
                        Text(game.machineSummary)
                    }
                    GridRow {
                        Text("Starts by").foregroundStyle(.secondary)
                        switch game.start {
                        case .boot: Text("Booting the disc")
                        case .insertOnly: Text("Putting the disc in")
                        case .type(let command):
                            Text(command.isEmpty ? "Putting the disc in" : command)
                                .font(.system(.callout, design: .monospaced))
                        }
                    }
                }
                .font(.callout)

                if let notes = game.notes {
                    Text(notes)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if game.discFile != nil || !snapshots.isEmpty {
                    SnapshotList(snapshots: snapshots, ownerTitle: game.title)
                }
            }
            .padding(16)
        }
        .task(id: "\(game.id)-\(classics.snapshotChanges)") {
            snapshots = await classics.snapshots.history(owner: game.id)
        }
    }
}
