import BeebCore
import BeebNetwork
import CGtk
import Foundation
import Observation

/// Network ▸ Join a Network…: a code someone read out, or an invitation
/// link, to the room it's for; then which network joins it. Also opened
/// by macbeeb://join links from an invitation's web page. (The Mac's
/// JoinRoomView.)
@MainActor
final class JoinRoomWindow {
    static let key = "join-econet"

    static func show() {
        Windows.show(key) { JoinRoomWindow().window }
    }

    /// Add Remote Elite…: joining an Elite over Econet game with a player
    /// of one's own (the invitation's code or link still needed).
    static func showForElite() {
        JoinRequests.shared.requestElite()
        show()
    }

    enum Target: Hashable {
        case newModelB
        case newMaster
        /// An Elite over Econet player, for a network with the game's
        /// file server (and its scoreboard).
        case newElite
        case network(URL)
    }

    /// What was typed or pasted, read: a code (for the service in use), or a
    /// link (which names its own service).
    struct Invitation: Equatable {
        var service: URL
        var code: String?
        var token: String?
    }

    static func invitation(from typed: String) -> Invitation? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "macbeeb" || scheme == "macarch", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               let service = items.first(where: { $0.name == "service" })?.value.flatMap({ try? InternetEconetService.validate($0).get() }),
               let token = items.first(where: { $0.name == "invite" })?.value {
                return Invitation(service: service, token: token)
            }
            if scheme == "https" || scheme == "http", url.path.hasPrefix("/join/"),
               let origin = try? InternetEconetService.validate("\(scheme)://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")").get() {
                return Invitation(service: origin, token: String(url.path.dropFirst("/join/".count)))
            }
        }
        return Invitation(service: InternetEconetService.current, code: text)
    }

    let window: Window
    private let state = JoinState()
    private let codeRow = EntryRow("Code or invitation link")
    private let lookUp: InternetBusyButton
    private let join: InternetBusyButton
    private let otherServiceText = Label().wrap()
    private let otherServiceNotice: Box
    private let errorText = Label().wrap().selectable()
    private let errorNotice: Box
    private let settingsButton = Button("Internet Econet Service Settings…")
    private let preview = Box(.vertical, spacing: 18)
    private let roomName = Label("", style: "title-3").wrap()
    private let roomDescription = Label("", style: "dim-label").wrap()
    private let roomPeople = Label("", style: "dim-label").wrap()
    private let stations = ListBox().style("boxed-list")
    private let targetRow = ComboRow("Join with", items: [""])
    private let clashRow = ActionRow("")
    private let nameRow = EntryRow("Your name")
    private let screenRow = SwitchRow("Show my machine's screen to the others",
                                      subtitle: "This network lets people share their screens: yours appears, live, on their canvas. You can change your mind later.")
    private let defaultRow = SwitchRow("")
    /// The choices in "Join with", as listed.
    private var targets: [Target] = []
    private var observer: NSObjectProtocol?

    private init() {
        InternetStyles.install()
        window = Window(title: "Join Econet Network")
        lookUp = InternetBusyButton("_Look Up") {}
        join = InternetBusyButton("_Join") {}
        let otherServiceText = otherServiceText, errorText = errorText
        otherServiceNotice = Box(.horizontal, spacing: 10) {
            Icon("dialog-warning-symbolic").align(vertical: GTK_ALIGN_START).style("warning")
            otherServiceText.expand(horizontal: true).style("warning")
        }
        errorNotice = Box(.horizontal, spacing: 10) {
            Icon("dialog-error-symbolic").align(vertical: GTK_ALIGN_START).style("error")
            errorText.expand(horizontal: true).style("error")
        }
        build()
        observe()
        takeRequests()
        window.keep(self)
    }

    // MARK: Building

    private func build() {
        let cancel = Button("_Cancel") { [window] in window.close() }
        join.button.style("suggested-action").enabled(false)
        join.button.onClicked { [weak self] in self?.joinRoom() }
        let header = HeaderBar(title: WindowTitle("Join Econet Network"))
            .start(cancel)
            .end(join.button)
            .showsWindowButtons(start: false, end: false)

        let intro = Box(.horizontal, spacing: 14) {
            InternetGlobe(size: 40)
            Box(.vertical, spacing: 2) {
                Label("Join an Econet Network", style: "title-2").wrap()
                Label("Enter the code you were given, or paste the invitation link.", style: "dim-label").wrap()
            }
            .align(vertical: GTK_ALIGN_CENTER)
            .expand(horizontal: true)
        }

        lookUp.button.align(vertical: GTK_ALIGN_CENTER).enabled(false)
            .tooltip("Find the network the code or link is for")
        lookUp.button.onClicked { [weak self] in self?.lookUpInvitation() }
        codeRow.monospaceText().placeholderText("ACRN-XXXX-XXXX-XXXX or a link").suffix(lookUp.button)
        codeRow.onReturn { [weak self] in self?.lookUpInvitation() }
        codeRow.object.on("changed") { [weak self] in
            guard let self else { return }
            self.state.typed = self.codeRow.text
            self.state.preview = nil
            self.state.error = nil
        }
        let codeGroup = PreferencesGroup { codeRow }

        settingsButton.align(horizontal: GTK_ALIGN_START).onClicked { PreferencesWindow.show(page: .networking) }
        let errorBox = Box(.vertical, spacing: 10) {
            errorNotice
            settingsButton
        }

        buildPreview()

        let body = Box(.vertical, spacing: 18) {
            intro
            codeGroup
            otherServiceNotice
            errorBox
            preview
        }
        .margin(top: 12, bottom: 24, start: 24, end: 24)
        // (Sized to what it shows, as the Mac's is: taller with a room.)
        let scroller = ScrolledWindow(body.size(width: 560), horizontal: GTK_POLICY_NEVER)
            .propagateNaturalHeight()
            .maxContentHeight(700)
        let content = ToolbarView(content: scroller).top(header)
        window.content = content
        window.resizable(false)
        join.button.isDefault(in: window)
        window.shortcut("Escape", action: "window.close")
        App.addStandardShortcuts(to: window)
        codeRow.grabFocus()

        let state = state
        errorBox.track {
            errorBox.isVisible = state.error != nil
        }
    }

    private func buildPreview() {
        let room = Box(.vertical, spacing: 4) {
            roomName
            roomDescription
            roomPeople
        }
        // (The choice under the title: the choices are long.)
        adw_combo_row_set_use_subtitle(cast(targetRow.widget), 1)
        targetRow.object.onChange("selected") { [weak self] in
            guard let self, self.targets.indices.contains(self.targetRow.selected) else { return }
            let target = self.targets[self.targetRow.selected]
            if self.state.target != target { self.state.target = target }
        }
        clashRow.style("internet-title-warning")
        clashRow.prefix(Icon("dialog-warning-symbolic").style("warning"))
        clashRow.focusable(false)
        nameRow.text = state.displayName
        nameRow.placeholderText("Shown to the others").returnActivatesDefault()
        nameRow.object.on("changed") { [weak self] in
            guard let self else { return }
            self.state.displayName = self.nameRow.text
        }
        screenRow.object.onChange("active") { [weak self] in
            guard let self else { return }
            self.state.showScreen = self.screenRow.isOn
        }
        defaultRow.object.onChange("active") { [weak self] in
            guard let self else { return }
            self.state.makeDefault = self.defaultRow.isOn
        }
        let options = PreferencesGroup {
            targetRow
            clashRow
            nameRow
            screenRow
            defaultRow
        }
        let footnote = Label("Your machines' Econet joins the network; nothing else on your computer is shared.",
                             style: "caption", "dim-label").wrap()
        preview.append(room)
        preview.append(stations)
        preview.append(options)
        preview.append(footnote)
    }

    // MARK: State

    private func observe() {
        let state = state
        window.track { [weak self] in
            guard let self else { return }
            let invitation = Self.invitation(from: state.typed)
            self.lookUp.isBusy = state.lookingUp
            self.lookUp.button.isEnabled = invitation != nil && !state.lookingUp
            self.join.isBusy = state.joining
            self.join.button.isEnabled = state.preview != nil && !state.joining
            self.codeRow.isEnabled = !state.joining

            let other = self.otherService(invitation)
            self.otherServiceNotice.isVisible = other != nil
            if let other {
                self.otherServiceText.text = "This invitation is for \(other.host ?? other.absoluteString), not the service you use (\(InternetEconetService.current.host ?? "")). Only join if you trust whoever sent it."
            }

            if let error = state.error {
                self.errorText.text = error
                self.settingsButton.isVisible = invitation?.code != nil && !InternetEconetService.isOfficial || error.contains("different")
            }
        }
        window.track { [weak self] in
            // The room previewed (rebuilt only when it changes).
            guard let self else { return }
            self.show(state.preview)
        }
        window.track { [weak self] in
            guard let self, let preview = state.preview else { return }
            let other = self.otherService(Self.invitation(from: state.typed))
            self.screenRow.isVisible = preview.room.allowsScreens
            self.defaultRow.isVisible = other != nil
            if let other {
                adw_preferences_row_set_title(cast(self.defaultRow.widget), "Use \(other.host ?? "") for my own networks too")
            }
            self.updateClash(preview, target: state.target)
        }
        let center = NotificationCenter.default
        observer = center.addObserver(forName: JoinRequests.arrived, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeRequests() }
        }
        window.onDestroy { [weak self] in
            if let observer = self?.observer { center.removeObserver(observer) }
        }
    }

    /// An invitation to another service than the one set.
    private func otherService(_ invitation: Invitation?) -> URL? {
        guard let invitation,
              InternetEconetService.origin(invitation.service) != InternetEconetService.origin(InternetEconetService.current) else { return nil }
        return invitation.service
    }

    /// A link that opened MacBeeb, or Add Remote Elite.
    private func takeRequests() {
        if JoinRequests.shared.takeElite() {
            state.target = .newElite
            if let index = targets.firstIndex(of: .newElite) { targetRow.selected = index }
        }
        if let pending = JoinRequests.shared.take() {
            codeRow.text = pending.absoluteString
            state.typed = pending.absoluteString
            lookUpInvitation()
        }
        window.present()
    }

    private var lastShown: InvitePreview?

    private func show(_ preview: InvitePreview?) {
        self.preview.isVisible = preview != nil
        guard let preview, preview != lastShown else {
            if preview == nil { lastShown = nil }
            return
        }
        lastShown = preview
        let host = Self.invitation(from: state.typed)?.service.host ?? ""
        roomName.text = preview.room.name
        roomDescription.text = preview.room.description
        roomDescription.isVisible = !preview.room.description.isEmpty
        roomPeople.text = "\(preview.participants) \(preview.participants == 1 ? "person" : "people") · on \(host)"
        stations.set(preview.stations.map { station in
            ActionRow(station.label, subtitle: station.kind).prefix(InternetStationBadge(station.station))
        })
        stations.isVisible = !preview.stations.isEmpty

        let open = NetworkSession.open.values.filter { !$0.isInRoom }.sorted { $0.project.name < $1.project.name }
        targets = [.newModelB, .newMaster, .newElite] + open.map { .network($0.url) }
        let labels = ["A new network with a BBC Model B", "A new network with a BBC Master 128",
                      "A new network with an Elite over Econet player"]
            + open.map { "“\($0.project.name)”, open now" }
        if !targets.contains(state.target) { state.target = .newModelB }
        targetRow.setItems(labels, selected: targets.firstIndex(of: state.target) ?? 0)
        screenRow.isOn = state.showScreen
    }

    /// Machines of the network chosen whose numbers someone in the room has.
    private func updateClash(_ preview: InvitePreview, target: Target) {
        guard case .network(let url) = target, let session = NetworkSession.existing(url) else {
            clashRow.isVisible = false
            return
        }
        let taken = Set(preview.stations.map(\.station))
        let clashes = session.project.stations.filter { $0.stationNumber.map(taken.contains) ?? false }
        clashRow.isVisible = !clashes.isEmpty
        clashRow.title = "\(clashes.map { "\($0.name) (\($0.stationNumber ?? 0))" }.joined(separator: ", ")): someone in the network has that station number already. Once you've joined, MacBeeb offers a free one."
    }

    // MARK: Looking up and joining

    private func lookUpInvitation() {
        guard let invitation = Self.invitation(from: state.typed), !state.lookingUp else { return }
        state.lookingUp = true
        state.error = nil
        let state = state
        Task {
            defer { state.lookingUp = false }
            do {
                let api = RoomAPI(service: invitation.service)
                let info = try await api.serviceInfo()
                if let problem = info.incompatibility {
                    state.error = "\(invitation.service.host ?? ""): \(problem)."
                    return
                }
                let found = try await api.resolve(code: invitation.code, token: invitation.token)
                // (Unless what's typed changed meanwhile.)
                if Self.invitation(from: state.typed) == invitation { state.preview = found }
            } catch let problem as RoomAPIError {
                state.error = problem.message
            } catch {
                state.error = "Couldn't reach \(invitation.service.host ?? "the service"). Check the Internet connection, and the address."
            }
        }
    }

    private func joinRoom() {
        guard let invitation = Self.invitation(from: state.typed), let preview = state.preview, !state.joining else { return }
        state.joining = true
        let state = state
        let displayName = state.displayName.trimmingCharacters(in: .whitespaces)
        NetworkSession.roomDisplayName = displayName
        let target = state.target
        let showScreen = state.showScreen && preview.room.allowsScreens
        let makeDefault = state.makeDefault && otherService(invitation) != nil
        Task { [weak self] in
            defer { state.joining = false }
            do {
                let api = RoomAPI(service: invitation.service)
                let joined = try await api.join(roomId: preview.roomId, code: invitation.code, token: invitation.token,
                                                displayName: displayName.isEmpty ? "Guest" : displayName)
                let session: NetworkSession
                switch target {
                case .network(let url):
                    session = try NetworkSession.session(for: url)
                case .newModelB, .newMaster, .newElite:
                    session = try Self.makeNetwork(for: preview, model: target == .newMaster ? .master128 : .modelB,
                                                   elite: target == .newElite)
                }
                try session.enterRoom(service: invitation.service, roomId: preview.roomId, roomName: preview.room.name,
                                      joined: joined, shared: Set(session.project.stations.map(\.id)), showsScreens: showScreen)
                if makeDefault { InternetEconetService.current = invitation.service }
                NetworkStudioWindow.show(session.url)
                self?.window.close()
            } catch let problem as RoomAPIError {
                state.error = problem.message
            } catch {
                state.error = "Couldn't join: \(error)"
            }
        }
    }

    /// A network of its own for the room: one machine, at a station number
    /// nobody in the room has, and a clock. An Elite player plays as a
    /// commander nobody in the room is (by its machines' names) and reports
    /// to the room's scoreboard.
    static func makeNetwork(for preview: InvitePreview, model: BBCMicro.Model, elite: Bool = false,
                            in folder: URL = RecentNetworks.draftsFolder) throws -> NetworkSession {
        let taken = Set(preview.stations.map(\.station))
        let number = (1...253).first { !taken.contains($0) && $0 != 235 } ?? 1
        var project = NetworkProject(name: preview.room.name)
        let station: NetworkNode
        if elite {
            station = EliteOverEconet.remotePlayer(number: number, joining: preview.stations.map { ($0.station, $0.label) })
        } else {
            station = NetworkNode(kind: .station, name: model == .modelB ? "BBC \(number)" : "Master \(number)", stationNumber: number,
                                  setup: MachineSetup(model: model), position: CanvasPoint(x: 0, y: 0))
        }
        project.nodes = [station, .clock(at: CanvasPoint(x: 0, y: NetworkProject.rowSpacing))]
        project.workspace.tiles = project.stations.map(\.id)
        project.draft = true
        let url = RecentNetworks.newURL(named: preview.room.name, in: folder)
        try NetworkPackage.save(project, to: url)
        return try NetworkSession.session(for: url)
    }
}

/// What the Join window's showing.
@Observable @MainActor
private final class JoinState {
    var typed = ""
    var preview: InvitePreview?
    var lookingUp = false
    var joining = false
    var error: String?
    var target = JoinRoomWindow.Target.newModelB
    var displayName = NetworkSession.roomDisplayName
    var makeDefault = false
    var showScreen = false
}
