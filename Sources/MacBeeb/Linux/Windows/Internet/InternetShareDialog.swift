import BeebNetwork
import CGtk
import Foundation
import Observation

/// Network ▸ Share Over Internet: put this network's machines in a private
/// room others join with a link or a code; then the room's invitation,
/// who's in it, and the host's controls. For a network that joined someone
/// else's room, the room and leaving it. (The Mac's InternetShareView.)
@MainActor
final class InternetShareDialog {
    static func present(session: NetworkSession, over parent: Widget?) {
        InternetStyles.install()
        let controller = InternetShareDialog(session: session)
        controller.dialog.present(over: parent ?? Application.shared.activeWindow.map(Widget.init))
    }

    /// How long invitations last (the last choice, for next time).
    static let lifeKey = "InternetInvitationLife"

    static var invitationLife: InvitationLife {
        get { UserDefaults.standard.string(forKey: lifeKey).flatMap(InvitationLife.init(rawValue:)) ?? .day }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lifeKey) }
    }

    /// How long an invitation works, and for how many.
    static func terms(of invite: Invite) -> String {
        let people = invite.maxUses.map { "for up to \($0) people" } ?? "for any number of people"
        guard let expiry = invite.expiry else { return "Never expires, \(people), until you withdraw it or stop sharing." }
        return "Works until \(expiry.formatted(date: .abbreviated, time: .shortened)), \(people)."
    }

    let session: NetworkSession
    let dialog: Dialog
    private let state = ShareState()
    private let pages = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    private let toasts: ToastOverlay

    private init(session: NetworkSession) {
        self.session = session
        state.roomName = session.project.name
        state.shared = Set(session.project.internetRoom?.shared ?? Self.defaultShared(session))
        toasts = ToastOverlay(pages)
        // (The pages have their own headings.)
        let header = HeaderBar(title: Widget(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)))
        dialog = Dialog(title: "Share Over Internet", content: ToolbarView(content: toasts).top(header))
        // As tall as what it shows (up to a limit, then scrolling), and
        // following it as it changes.
        adw_dialog_set_follows_content_size(cast(dialog.widget), 1)
        pages.sizesToVisible()
        pages.add(setUpPage(), name: "setup")
        pages.add(roomPage(), name: "room")
        let pages = pages
        pages.track { [weak self] in
            guard let self else { return }
            let inRoom = session.isInRoom
            pages.visible = inRoom ? "room" : "setup"
            adw_dialog_set_title(cast(self.dialog.widget), inRoom ? "Internet Network" : "Share Over Internet")
        }
        dialog.keep(self)
    }

    /// Machines shared by default: stations, not servers (sharing a server
    /// is a decision); except a Level 3 server, which is Elite over
    /// Econet's, there for remote commanders to play from.
    static func defaultShared(_ session: NetworkSession) -> [UUID] {
        session.project.stations.filter { $0.kind == .station || $0.level == .level3 && $0.kind == .fileServer }.map(\.id)
    }

    private var service: URL { InternetEconetService.current }

    private func fail(_ message: String) {
        AlertDialog("Internet Econet", body: message)
            .response("ok", "_OK", .suggested)
            .defaults(default: "ok", close: "ok")
            .present(over: dialog)
    }

    // MARK: Before sharing

    private func setUpPage() -> Widget {
        let state = state
        let intro = Box(.vertical, spacing: 8) {
            InternetGlobe(size: 64).margin(bottom: 4)
            Label("Share Over the Internet", style: "title-2").centred().wrap()
            Label("A private Econet network others join with a link or a code, from MacBeeb or MacArch. Their BBC Micros and Archimedes appear on your network, and yours on theirs.",
                  style: "dim-label").centred().wrap()
        }
        let nameRow = EntryRow("Network name", text: state.roomName) { state.roomName = $0 }
        let displayRow = EntryRow("Your name", text: state.displayName) { state.displayName = $0 }
            .placeholderText("Shown to people who join")
        let lives = InvitationLife.allCases
        let lifeRow = ComboRow("Invitation lasts", items: lives.map(\.displayName),
                               selected: lives.firstIndex(of: Self.invitationLife) ?? 1) { index in
            Self.invitationLife = lives[index]
        }
        let serviceRow = ActionRow("Service").suffix(Label(service.host ?? service.absoluteString, style: "dim-label").selectable())
        let form = PreferencesGroup {
            nameRow
            displayRow
            lifeRow
            serviceRow
        }

        let machines = PreferencesGroup(title: "Machines to share")
        let list = ListBox().style("boxed-list")
        machines.add(list)
        let machineList = SharedMachineList(session: session, state: state, host: list, add: list.append, remove: { row in
            gtk_list_box_remove(cast(list.widget), row.widget)
        })
        list.keep(machineList)

        let allow = SwitchRow("Let people share their machines' screens",
                              subtitle: "People in the network can choose to show their machines' screens, live, on everyone's canvas") { on in
            state.allowScreens = on
            if !on { state.showMine = false }
        }
        let showMine = SwitchRow("Show my machines' screens") { on in state.showMine = on }
        let note = Label("", style: "dim-label").wrap().margin(top: 12)
        let screens = PreferencesGroup {
            allow
            showMine
        }
        screens.add(note)
        screens.track {
            showMine.isEnabled = state.allowScreens
            showMine.isOn = state.showMine
            note.text = state.allowScreens
                ? "Screens go apart from Econet, a picture a second, and never get in its way. Nobody can type into your machines or reach anything else on your computer."
                : "Only Econet is shared: people who join can't see your screens, type into your machines or reach anything else on your computer."
        }

        let create = InternetBusyButton("Create Private Network") { [weak self] in self?.create() }
        create.button.style("suggested-action", "pill").align(horizontal: GTK_ALIGN_CENTER)
        let actions = PreferencesGroup()
        actions.add(create.button)
        actions.track {
            create.isBusy = state.busy
            create.button.isEnabled = !state.busy && !state.roomName.trimmingCharacters(in: .whitespaces).isEmpty
                && !state.shared.isEmpty
        }
        // Return in a field creates it.
        for row in [nameRow, displayRow] {
            row.onReturn { [weak self] in
                guard create.button.isEnabled else { return }
                self?.create()
            }
        }

        return Self.page {
            intro
            form
            machines
            screens
            actions
        }
    }

    /// Groups, one under another, scrolling when there are more than fit
    /// (and otherwise as tall as they are, for the dialog to fit them).
    static func page(@WidgetList _ groups: () -> [Widget]) -> Widget {
        let column = Box(.vertical, spacing: 24, groups)
        column.margin(top: 12, bottom: 24, start: 24, end: 24)
        // (A dialog whose content's natural height doesn't fit its window
        // shrinks to its minimum: so a natural height that fits, and a
        // minimum that's still useful.)
        let scroller = ScrolledWindow(column, horizontal: GTK_POLICY_NEVER)
            .propagateNaturalHeight()
            .propagateNaturalWidth()
            .maxContentHeight(640)
            .minContentHeight(320)
        // 560 wide, or narrower in a narrow window (a bottom sheet).
        let clamp = Clamp(scroller, maximum: 560)
        adw_clamp_set_tightening_threshold(cast(clamp.widget), 560)
        return clamp
    }

    private func create() {
        guard !state.busy else { return }
        let state = state
        state.busy = true
        NetworkSession.roomDisplayName = state.displayName.trimmingCharacters(in: .whitespaces)
        let session = session, service = service
        Task { [weak self] in
            defer { state.busy = false }
            do {
                try await session.share(on: service, name: state.roomName.trimmingCharacters(in: .whitespaces), shared: state.shared,
                                        screenSharing: state.allowScreens, showsScreens: state.showMine,
                                        invitation: Self.invitationLife)
            } catch {
                self?.fail("Couldn't create the network: \(error)")
            }
        }
    }

    // MARK: Shared

    private var hosting: Bool { session.project.internetRoom?.hosting == true }

    private func roomPage() -> Widget {
        let session = session
        let title = Label("", style: "title-2").wrap()
        let summary = Label("", style: "dim-label").wrap()
        let badge = ConnectionBadge.make { session.room?.state }
        badge.align(vertical: GTK_ALIGN_START).margin(top: 6)
        let problemText = Label("").wrap().style("warning")
        let problem = Box(.horizontal, spacing: 8) {
            Icon("network-offline-symbolic").style("warning").align(vertical: GTK_ALIGN_START)
            problemText.expand(horizontal: true)
        }
        let endedText = Label("").wrap().style("error")
        let ended = Box(.horizontal, spacing: 8) {
            Icon("process-stop-symbolic").style("error").align(vertical: GTK_ALIGN_START)
            endedText.expand(horizontal: true)
        }
        let heading = Box(.vertical, spacing: 12) {
            Box(.horizontal, spacing: 12) {
                Box(.vertical, spacing: 2) {
                    title
                    summary
                }
                .expand(horizontal: true)
                badge
            }
            problem
            ended
            RoomConflictsView.make(session: session)
        }
        heading.track {
            let link = session.project.internetRoom
            let room = session.room
            title.text = room?.room?.name ?? link?.roomName ?? ""
            let people = room?.participants.count ?? 0
            summary.text = "Private · \(people) \(people == 1 ? "person" : "people") · \(link?.service.host ?? "")"
            if let text = room?.problem, room?.state != .connected {
                problemText.text = text
                problem.isVisible = true
            } else {
                problem.isVisible = false
            }
            if case .ended(let reason) = room?.state {
                endedText.text = reason
                ended.isVisible = true
            } else {
                ended.isVisible = false
            }
        }

        let invitation = invitationGroup()
        let people = participantsGroup()
        let access = accessGroup()

        let machines = ExpanderRow("Machines shared")
        let machineList = SharedMachineList(session: session, state: state, host: machines, add: machines.add, remove: { row in
            adw_expander_row_remove(cast(machines.widget), row.widget)
        })
        machines.keep(machineList)
        let machinesGroup = PreferencesGroup { machines }

        let leave = ButtonRow("") { [weak self] in self?.confirmLeaving() }
        leave.style("destructive-action")
        let leaveGroup = PreferencesGroup { leave }
        leaveGroup.track { [weak self] in
            guard let self else { return }
            adw_preferences_row_set_title(cast(leave.widget), self.hosting ? "Stop Sharing…" : "Leave Network…")
        }

        return Self.page {
            heading
            invitation
            people
            access
            machinesGroup
            leaveGroup
        }
    }

    // MARK: The invitation

    private func invitationGroup() -> Widget {
        let session = session
        let group = PreferencesGroup(title: "Invitation")
        let codeRow = ActionRow("Join code").property().subtitleSelectable().style("internet-code")
        let linkRow = ActionRow("Invite link").property().subtitleSelectable().subtitleLines(1)
        codeRow.suffix(copyButton("Copy Code") { session.currentInvite?.code })
        linkRow.suffix(copyButton("Copy Link") { session.currentInvite?.url })
        let lives = InvitationLife.allCases
        let lifeRow = ComboRow("Lasts", items: lives.map(\.displayName),
                               selected: lives.firstIndex(of: Self.invitationLife) ?? 1) { [weak self] index in
            Self.invitationLife = lives[index]
            // Choosing makes a new invitation that lasts this long (once
            // there is one).
            if session.currentInvite != nil { self?.newInvitation() }
        }
        let withdraw = Button("_Withdraw") { [weak self] in self?.withdraw() }
            .tooltip("The link and code stop working; anyone already in stays")
        let new = Button("_New Invitation") { [weak self] in self?.newInvitation() }
        let buttons = Box(.horizontal, spacing: 6) {
            withdraw
            new
        }
        buttons.align(vertical: GTK_ALIGN_CENTER)
        group.headerSuffix(buttons)
        group.add(codeRow)
        group.add(linkRow)
        group.add(lifeRow)
        group.track { [weak self] in
            guard let self else { return }
            group.isVisible = self.hosting
            let invite = session.currentInvite
            codeRow.isVisible = invite != nil
            linkRow.isVisible = invite != nil
            withdraw.isVisible = invite != nil
            codeRow.subtitle = invite?.code ?? ""
            linkRow.subtitle = invite?.url ?? ""
            if let invite {
                group.detail = Self.terms(of: invite)
                lifeRow.subtitle = "Choosing makes a new invitation that lasts this long; the one before still works until it expires or you withdraw it"
            } else {
                group.detail = "Make an invitation to let someone join: a link to send, or a code to read out."
                lifeRow.subtitle = ""
            }
        }
        return group
    }

    private func copyButton(_ label: String, _ text: @escaping @MainActor () -> String?) -> Widget {
        let button = Button(icon: "edit-copy-symbolic")
        button.style("flat").align(vertical: GTK_ALIGN_CENTER).tooltip(label).accessibleLabel(label)
        let toasts = toasts
        button.onClicked {
            guard let text = text() else { return }
            Clipboard.setText(text)
            button.iconName = "object-select-symbolic"
            button.tooltip("Copied")
            toasts.show("Copied")
            macbeeb_announce(button.widget, "Copied")
            MainLoop.after(2) {
                button.iconName = "edit-copy-symbolic"
                button.tooltip(label)
            }
        }
        return button
    }

    private func newInvitation() {
        let session = session
        Task { [weak self] in
            do { try await session.newInvitation(lasting: Self.invitationLife) } catch {
                self?.fail("Couldn't make an invitation: \(error)")
            }
        }
    }

    private func withdraw() {
        let session = session
        Task { try? await session.withdrawInvitation() }
    }

    // MARK: Who's in it

    private func participantsGroup() -> Widget {
        let group = PreferencesGroup(title: "In the network")
        let list = ListBox().style("boxed-list")
        list.placeholder(Label("Nobody yet", style: "dim-label").centred().margin(12))
        group.add(list)
        let people = ParticipantList(session: session, list: list)
        list.keep(people)
        return group
    }

    // MARK: Who can join, and screens

    private func accessGroup() -> Widget {
        let session = session
        let group = PreferencesGroup()
        let open = SwitchRow("Let new people join")
        let allow = SwitchRow("Let people share their machines' screens")
        let show = SwitchRow("Show my machines' screens")
        group.add(open)
        group.add(allow)
        group.add(show)
        let isOpen = { session.room?.room?.locked != true }
        let allowed = { session.room?.room?.allowsScreens == true }
        func sync() {
            open.isOn = isOpen()
            allow.isOn = allowed()
            show.isOn = session.showsScreens
        }
        open.object.onChange("active") {
            let on = open.isOn
            guard on != isOpen() else { return }
            Task {
                try? await session.setRoomLocked(!on)
                sync()
            }
        }
        allow.object.onChange("active") { [weak self] in
            let on = allow.isOn
            guard on != allowed() else { return }
            Task {
                do { try await session.setScreenSharingAllowed(on) } catch { self?.fail("\(error)") }
                sync()
            }
        }
        show.object.onChange("active") {
            let on = show.isOn
            guard on != session.showsScreens else { return }
            session.setShowsScreens(on)
        }
        group.track { [weak self] in
            guard let self else { return }
            let hosting = self.hosting
            open.isVisible = hosting
            allow.isVisible = hosting
            sync()
            show.isEnabled = allowed()
            show.subtitle = allowed() ? "Everyone in the network sees your shared machines' screens, live, on their canvas"
                : "The network's host hasn't allowed screen sharing"
        }
        return group
    }

    // MARK: Leaving

    private func confirmLeaving() {
        let hosting = hosting
        let session = session
        AlertDialog(hosting ? "Stop sharing this network?" : "Leave this network?",
                    body: hosting
                        ? "The network closes for everyone in it: their machines disappear from yours, and yours from theirs. Its link and code stop working."
                        : "Your machines leave the network, and its machines disappear from yours.")
            .response("cancel", "_Cancel")
            .response("leave", hosting ? "_Stop Sharing" : "_Leave", .destructive)
            .defaults(default: "cancel", close: "cancel")
            .choose(over: dialog) { response in
                guard response == "leave" else { return }
                Task { await session.leaveRoom() }
            }
    }
}

/// What the Share dialog's showing.
@Observable @MainActor
private final class ShareState {
    var roomName = ""
    var displayName = NetworkSession.roomDisplayName
    var shared: Set<UUID> = []
    var busy = false
    var allowScreens = false
    var showMine = false
}

/// The network's machines, each shared or not: rows rebuilt only when the
/// machines change (so a check being toggled keeps its focus).
@MainActor
private final class SharedMachineList {
    private let session: NetworkSession
    private let state: ShareState
    private let add: (Widget) -> Void
    private let remove: (Widget) -> Void
    private var rows: [(id: UUID, row: ActionRow, check: Widget, warning: Widget)] = []
    private var shape: [Shape] = []

    private struct Shape: Equatable {
        var id: UUID
        var name: String
        var number: Int?
        var model: String
        var kind: NetworkNode.Kind
    }

    /// The rows go in with `add`, and out with `remove`, for as long as
    /// `host` (the list they're in) lives.
    init(session: NetworkSession, state: ShareState, host: Widget, add: @escaping (Widget) -> Void,
         remove: @escaping (Widget) -> Void) {
        self.session = session
        self.state = state
        self.add = add
        self.remove = remove
        host.track { [weak self] in self?.rebuild() }
        host.track { [weak self] in self?.update() }
    }

    private func rebuild() {
        let stations = session.project.stations
        let shape = stations.map { Shape(id: $0.id, name: $0.name, number: $0.stationNumber, model: $0.setup?.model.displayName ?? "",
                                         kind: $0.kind) }
        guard shape != self.shape else { return }
        self.shape = shape
        for entry in rows { remove(entry.row) }
        rows = shape.map { node in
            let row = ActionRow(node.name)
            let check = Widget(gtk_check_button_new())
            check.align(vertical: GTK_ALIGN_CENTER).accessibleLabel("Share \(node.name)")
            check.object.on("toggled") { [weak self] in
                guard let self else { return }
                let on = gtk_check_button_get_active(cast(check.widget)) != 0
                var shared = self.state.shared
                if on { shared.insert(node.id) } else { shared.remove(node.id) }
                guard shared != self.state.shared else { return }
                self.state.shared = shared
                if self.session.isInRoom { self.session.setShared(shared) }
            }
            // (Each prefix goes before the last.)
            row.prefix(InternetStationBadge(node.number))
            row.prefix(check)
            row.activates(check)
            row.suffix(Label(node.model, style: "dim-label"))
            let warning = Icon("dialog-warning-symbolic").style("warning").align(vertical: GTK_ALIGN_CENTER)
            row.suffix(warning)
            return (node.id, row, check, warning)
        }
        for entry in rows { add(entry.row) }
        update()
    }

    private func update() {
        let shared = state.shared
        for entry in rows {
            let on = shared.contains(entry.id)
            if (gtk_check_button_get_active(cast(entry.check.widget)) != 0) != on {
                gtk_check_button_set_active(cast(entry.check.widget), on ? 1 : 0)
            }
            let kind = shape.first { $0.id == entry.id }?.kind ?? .station
            let warns = kind != .station && on
            entry.warning.isVisible = warns
            entry.row.setStyle("internet-subtitle-warning", warns)
            entry.row.subtitle = !warns ? ""
                : kind == .fileServer
                ? "People who join can log on to this file server and read and write whatever its accounts allow."
                : "People who join can print on this printer server: their jobs appear in your Print Centre."
        }
    }
}

/// Who's in the room: each person, their machines, how far away they are,
/// and (for the host) removing them. Rows are rebuilt as people come and
/// go; round trips change in place.
@MainActor
private final class ParticipantList {
    private let session: NetworkSession
    private let list: ListBox
    private var shape: [Shape] = []
    private var rtts: [String: Label] = [:]

    private struct Shape: Equatable {
        var id: String
        var title: String
        var machines: String
        var online: Bool
        var removable: Bool
    }

    init(session: NetworkSession, list: ListBox) {
        self.session = session
        self.list = list
        list.track { [weak self] in self?.update() }
    }

    private func update() {
        let room = session.room
        let hosting = session.project.internetRoom?.hosting == true
        let participants = room?.participants ?? []
        let shape = participants.map { person in
            let isMe = person.id == room?.participantId
            let stations = (room?.stations ?? []).filter { $0.participantId == person.id }
            return Shape(id: person.id, title: person.name + (isMe ? " (you)" : "") + (person.owner ? " · host" : ""),
                         machines: stations.isEmpty ? "No machines" : stations.map { "\($0.station) \($0.label)" }.joined(separator: ", "),
                         online: person.online, removable: hosting && !isMe)
        }
        if shape != self.shape {
            self.shape = shape
            rebuild()
        }
        for person in participants {
            guard let label = rtts[person.id] else { continue }
            let rtt = person.online ? person.rttMs : nil
            label.text = rtt.map { "\($0) ms" } ?? ""
            label.isVisible = rtt != nil
        }
    }

    private func rebuild() {
        let session = session
        rtts = [:]
        list.set(shape.map { person in
            let row = ActionRow(person.title, subtitle: person.machines)
            let dot = InternetStatusDot(person.online ? .online : .off)
            dot.widget.accessibleLabel(person.online ? "Online" : "Offline")
            row.prefix(dot.widget)
            row.keep(dot)
            let rtt = Label("", style: "dim-label", "numeric", "caption").visible(false)
            rtt.tooltip("Round trip to the service")
            row.suffix(rtt)
            rtts[person.id] = rtt
            if person.removable {
                let id = person.id
                row.suffix(Button("_Remove") { Task { try? await session.removeFromRoom(id) } }
                    .align(vertical: GTK_ALIGN_CENTER)
                    .tooltip("Take \(person.title) out of the network"))
            }
            return row
        })
    }
}

/// Machines whose station numbers someone else in the room already has,
/// each with a number to change to: the change (and the restart it needs,
/// for a machine that's on) only when asked. Hidden when there are none.
/// (In the studio it's laid over the top of whatever's shown.)
@MainActor
enum RoomConflictsView {
    static func make(session: NetworkSession) -> Widget {
        InternetStyles.install()
        let conflicts = RoomConflicts(session: session)
        let clamp = Clamp(conflicts.box, maximum: 640)
        // (Its full width up to 640, not tightening before then.)
        adw_clamp_set_tightening_threshold(cast(clamp.widget), 640)
        clamp.align(vertical: GTK_ALIGN_START)
        clamp.keep(conflicts)
        clamp.track {
            clamp.isVisible = !session.roomConflicts.isEmpty
        }
        return clamp
    }
}

@MainActor
private final class RoomConflicts {
    let session: NetworkSession
    let box = Box(.vertical, spacing: 8).style("internet-conflicts")
    private let rows = Box(.vertical, spacing: 8)
    private let problem = Label("", style: "error", "caption").wrap()
    private var shown: [NetworkSession.RoomConflict] = []

    init(session: NetworkSession) {
        self.session = session
        box.append(rows)
        box.append(problem)
        problem.visible(false)
        box.track { [weak self] in self?.update() }
    }

    private func update() {
        let conflicts = session.roomConflicts
        guard conflicts != shown else { return }
        shown = conflicts
        rows.set {
            for conflict in conflicts {
                row(conflict)
            }
        }
    }

    private func row(_ conflict: NetworkSession.RoomConflict) -> Widget {
        let row = Box(.horizontal, spacing: 10) {
            Icon("dialog-warning-symbolic").style("warning").align(vertical: GTK_ALIGN_CENTER)
            Label("Someone in the network already has station \(conflict.station), so \(conflict.name) isn't in it.")
                .wrap().expand(horizontal: true)
        }
        if let number = conflict.suggestion {
            row.append(Button("Change to \(number)…") { [weak self] in self?.confirm(conflict, number) }
                .align(vertical: GTK_ALIGN_CENTER)
                .tooltip("Give \(conflict.name) station number \(number), which nobody in the network has"))
        }
        return row
    }

    private func confirm(_ conflict: NetworkSession.RoomConflict, _ number: Int) {
        let session = session
        let problem = problem
        AlertDialog("Change \(conflict.name) to station \(number)?",
                    body: conflict.isOn
                        ? "Its network interface takes its number when it starts, so it starts again: what's in its memory is lost. Its discs stay in their drives."
                        : "It takes the new number when it's switched on.")
            .response("cancel", "_Cancel")
            .response("change", conflict.isOn ? "Change and _Restart" : "_Change", conflict.isOn ? .destructive : .suggested)
            .defaults(default: conflict.isOn ? "cancel" : "change", close: "cancel")
            .choose(over: box) { response in
                guard response == "change" else { return }
                let message = session.renumberForRoom(conflict.node, to: number)
                problem.text = message ?? ""
                problem.isVisible = message != nil
            }
    }
}
