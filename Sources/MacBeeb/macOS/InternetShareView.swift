import AppKit
import BeebNetwork
import SwiftUI

/// Network ▸ Share Over Internet: put this network's machines in a private
/// room others join with a link or a code; then the room's invitation,
/// who's in it, and the host's controls. For a network that joined someone
/// else's room, the room and leaving it.
struct InternetShareView: View {
    let session: NetworkSession
    @Environment(\.dismiss) private var dismiss
    @State private var roomName = ""
    @State private var displayName = NetworkSession.roomDisplayName
    @State private var shared: Set<UUID> = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingStop = false
    @State private var copied: String?
    @State private var allowScreens = false
    @State private var showMine = false
    /// How long invitations last (the last choice, for next time).
    @AppStorage("InternetInvitationLife") private var invitationLife: InvitationLife = .day

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.isInRoom {
                inRoom
            } else {
                setUp
            }
        }
        .frame(width: 520)
        .onAppear {
            roomName = session.project.name
            shared = Set(session.project.internetRoom?.shared ?? defaultShared)
        }
        .alert("Internet Econet", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Machines shared by default: stations, not servers (sharing a server
    /// is a decision); except a Level 3 server, which is Elite over
    /// Econet's, there for remote commanders to play from.
    private var defaultShared: [UUID] {
        session.project.stations.filter { $0.kind == .station || $0.level == .level3 && $0.kind == .fileServer }.map(\.id)
    }

    private var service: URL { InternetEconetService.current }

    // MARK: Before sharing

    private var setUp: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 30))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Over the Internet")
                        .font(.title2.weight(.semibold))
                    Text("A private Econet network others join with a link or a code, from MacBeeb or MacArch. Their BBC Micros and Archimedes appear on your network, and yours on theirs.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Form {
                TextField("Network name", text: $roomName)
                TextField("Your name", text: $displayName, prompt: Text("Shown to people who join"))
                lifePicker("Invitation lasts")
                LabeledContent("Service") {
                    Text(service.host ?? service.absoluteString)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            machineList
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Let people share their machines' screens", isOn: $allowScreens)
                    .help("People in the network can choose to show their machines' screens, live, on everyone's canvas")
                Toggle("Show my machines' screens", isOn: $showMine)
                    .disabled(!allowScreens)
                    .padding(.leading, 20)
            }
            .onChange(of: allowScreens) { if !allowScreens { showMine = false } }
            Text(allowScreens
                 ? "Screens go apart from Econet, a picture a second, and never get in its way. Nobody can type into your machines or reach anything else on your Mac."
                 : "Only Econet is shared: people who join can't see your screens, type into your machines or reach anything else on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Create Private Network") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || roomName.trimmingCharacters(in: .whitespaces).isEmpty || shared.isEmpty)
            }
        }
        .padding(20)
    }

    private var machineList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Machines to share")
                .font(.headline)
            ForEach(session.project.stations) { node in
                HStack {
                    Toggle(isOn: Binding(get: { shared.contains(node.id) }, set: { on in
                        if on { shared.insert(node.id) } else { shared.remove(node.id) }
                        if session.isInRoom { session.setShared(shared) }
                    })) {
                        HStack(spacing: 6) {
                            StationBadge(number: node.stationNumber)
                            Text(node.name)
                            Text(node.setup?.model.displayName ?? "")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                if node.kind != .station && shared.contains(node.id) {
                    Label(node.kind == .fileServer
                          ? "People who join can log on to this file server and read and write whatever its accounts allow."
                          : "People who join can print on this printer server: their jobs appear in your Print Centre.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.leading, 24)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func create() {
        busy = true
        NetworkSession.roomDisplayName = displayName.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                try await session.share(on: service, name: roomName.trimmingCharacters(in: .whitespaces), shared: shared,
                                        screenSharing: allowScreens, showsScreens: showMine, invitation: invitationLife)
            } catch {
                self.error = "Couldn't create the network: \(error)"
            }
        }
    }

    // MARK: Shared

    private var inRoom: some View {
        let link = session.project.internetRoom
        let room = session.room
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room?.room?.name ?? link?.roomName ?? "")
                        .font(.title2.weight(.semibold))
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ConnectionBadge(state: room?.state)
            }
            if let problem = room?.problem, room?.state != .connected {
                Label(problem, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if case .ended(let reason) = room?.state {
                Label(reason, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
            if link?.hosting == true {
                invitation
            }
            participants
            RoomConflictsView(session: session)
            screensControls
            DisclosureGroup("Machines shared") {
                machineList
                    .padding(.top, 6)
            }
            HStack {
                if link?.hosting == true {
                    Toggle("Let new people join", isOn: Binding(get: { room?.room?.locked != true }, set: { open in
                        Task { try? await session.setRoomLocked(!open) }
                    }))
                    .toggleStyle(.checkbox)
                }
                Spacer()
                Button(link?.hosting == true ? "Stop Sharing…" : "Leave Network…", role: .destructive) { confirmingStop = true }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .confirmationDialog(link?.hosting == true ? "Stop sharing this network?" : "Leave this network?", isPresented: $confirmingStop) {
            Button(link?.hosting == true ? "Stop Sharing" : "Leave", role: .destructive) {
                Task { await session.leaveRoom() }
            }
        } message: {
            Text(link?.hosting == true
                 ? "The network closes for everyone in it: their machines disappear from yours, and yours from theirs. Its link and code stop working."
                 : "Your machines leave the network, and its machines disappear from yours.")
        }
    }

    @ViewBuilder
    private var screensControls: some View {
        let allowed = session.room?.room?.allowsScreens == true
        VStack(alignment: .leading, spacing: 6) {
            if session.project.internetRoom?.hosting == true {
                Toggle("Let people share their machines' screens", isOn: Binding(get: { allowed }, set: { on in
                    Task {
                        do { try await session.setScreenSharingAllowed(on) } catch { self.error = "\(error)" }
                    }
                }))
            }
            Toggle("Show my machines' screens", isOn: Binding(get: { session.showsScreens }, set: { session.setShowsScreens($0) }))
                .disabled(!allowed)
                .help(allowed ? "Everyone in the network sees your shared machines' screens, live, on their canvas"
                      : "The network's host hasn't allowed screen sharing")
        }
    }

    private var summary: String {
        let people = session.room?.participants.count ?? 0
        let host = session.project.internetRoom?.service.host ?? ""
        return "Private · \(people) \(people == 1 ? "person" : "people") · \(host)"
    }

    @ViewBuilder
    private var invitation: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let invite = session.currentInvite {
                HStack {
                    Text("Join code")
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(invite.code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Spacer()
                    copyButton(invite.code, label: "Copy Code")
                }
                HStack {
                    Text("Invite link")
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(invite.url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    copyButton(invite.url, label: "Copy Link")
                }
                Text(Self.terms(of: invite))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    lifePicker("Lasts")
                        .fixedSize()
                        .help("Choosing makes a new invitation that lasts this long; the one before still works until it expires or you withdraw it")
                        .onChange(of: invitationLife) { newInvitation() }
                    Spacer()
                    Button("Withdraw") { Task { try? await session.withdrawInvitation() } }
                        .help("The link and code stop working; anyone already in stays")
                    Button("New Invitation") { newInvitation() }
                }
            } else {
                HStack {
                    Text("Make an invitation to let someone join: a link to send, or a code to read out.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    lifePicker("Lasts")
                        .fixedSize()
                    Button("New Invitation") { newInvitation() }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func lifePicker(_ label: String) -> some View {
        Picker(label, selection: $invitationLife) {
            ForEach(InvitationLife.allCases) { Text($0.displayName).tag($0) }
        }
    }

    private func newInvitation() {
        Task {
            do { try await session.newInvitation(lasting: invitationLife) } catch { self.error = "Couldn't make an invitation: \(error)" }
        }
    }

    /// How long an invitation works, and for how many.
    static func terms(of invite: Invite) -> String {
        let people = invite.maxUses.map { "for up to \($0) people" } ?? "for any number of people"
        guard let expiry = invite.expiry else { return "Never expires, \(people), until you withdraw it or stop sharing." }
        return "Works until \(expiry.formatted(date: .abbreviated, time: .shortened)), \(people)."
    }

    private func copyButton(_ text: String, label: String) -> some View {
        Button(copied == text ? "Copied" : label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = text
        }
    }

    @ViewBuilder
    private var participants: some View {
        let room = session.room
        VStack(alignment: .leading, spacing: 6) {
            Text("In the network")
                .font(.headline)
            ForEach(room?.participants ?? []) { person in
                let isMe = person.id == room?.participantId
                let stations = (room?.stations ?? []).filter { $0.participantId == person.id }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(person.online ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name + (isMe ? " (you)" : "") + (person.owner ? " · host" : ""))
                        Text(stations.isEmpty ? "No machines" : stations.map { "\($0.station) \($0.label)" }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let rtt = person.rttMs, person.online {
                        Text("\(rtt) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if session.project.internetRoom?.hosting == true && !isMe {
                        Button("Remove") { Task { try? await session.removeFromRoom(person.id) } }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Connected, reconnecting, or not.
struct ConnectionBadge: View {
    let state: RoomConnection.State?

    var body: some View {
        let (text, colour): (String, Color) = switch state {
        case .connected: ("Connected", .green)
        case .connecting, nil: ("Connecting…", .orange)
        case .reconnecting: ("Reconnecting…", .orange)
        case .ended: ("Disconnected", .red)
        case .stopped: ("Not connected", .secondary)
        }
        Label {
            Text(text)
        } icon: {
            Circle().fill(colour).frame(width: 8, height: 8)
        }
        .font(.callout)
    }
}

/// Machines whose station numbers someone else in the room already has,
/// each with a number to change to: the change (and the restart it needs,
/// for a machine that's on) only when asked.
struct RoomConflictsView: View {
    let session: NetworkSession
    @State private var confirming: NetworkSession.RoomConflict?
    @State private var problem: String?

    var body: some View {
        let conflicts = session.roomConflicts
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(conflicts) { conflict in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Someone in the network already has station \(conflict.station), so \(conflict.name) isn't in it.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let number = conflict.suggestion {
                            Button("Change to \(number)…") { confirming = conflict }
                                .help("Give \(conflict.name) station number \(number), which nobody in the network has")
                        }
                    }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .confirmationDialog(confirming.map { "Change \($0.name) to station \($0.suggestion ?? 0)?" } ?? "",
                                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                Button(confirming?.isOn == true ? "Change and Restart" : "Change") {
                    if let conflict = confirming, let number = conflict.suggestion {
                        problem = session.renumberForRoom(conflict.node, to: number)
                    }
                    confirming = nil
                }
            } message: {
                Text(confirming?.isOn == true
                     ? "Its network interface takes its number when it starts, so it starts again: what's in its memory is lost. Its discs stay in their drives."
                     : "It takes the new number when it's switched on.")
            }
        }
    }
}
