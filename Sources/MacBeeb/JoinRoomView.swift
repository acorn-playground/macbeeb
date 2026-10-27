import AppKit
import BeebCore
import BeebNetwork
import SwiftUI

/// File ▸ Join Econet Network…: a code someone read out, or an invitation
/// link, to the room it's for; then which network joins it. Also opened
/// by macbeeb://join links from an invitation's web page.
struct JoinRoomView: View {
    static let windowID = "join-econet"
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var typed = ""
    @State private var preview: InvitePreview?
    @State private var lookingUp = false
    @State private var joining = false
    @State private var error: String?
    @State private var target = Target.newModelB
    @State private var displayName = NetworkSession.roomDisplayName
    @State private var makeDefault = false
    @State private var showScreen = false

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
    private struct Invitation: Equatable {
        var service: URL
        var code: String?
        var token: String?
    }

    private var invitation: Invitation? {
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

    /// An invitation to another service than the one set.
    private var otherService: URL? {
        guard let invitation, InternetEconetService.origin(invitation.service) != InternetEconetService.origin(InternetEconetService.current) else { return nil }
        return invitation.service
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 30))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Join an Econet Network")
                        .font(.title2.weight(.semibold))
                    Text("Enter the code you were given, or paste the invitation link.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("ACRN-XXXX-XXXX-XXXX or a link", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                    .onSubmit(lookUp)
                    .onChange(of: typed) { preview = nil; error = nil }
                Button("Look Up", action: lookUp)
                    .disabled(invitation == nil || lookingUp)
            }
            if let otherService {
                Label("This invitation is for \(otherService.host ?? otherService.absoluteString), not the service you use (\(InternetEconetService.current.host ?? "")). Only join if you trust whoever sent it.",
                      systemImage: "exclamationmark.shield")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if lookingUp {
                ProgressView().controlSize(.small)
            }
            if let error {
                Label(error, systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if invitation?.code != nil && !InternetEconetService.isOfficial || error.contains("different") {
                    SettingsLink { Text("Internet Econet Service Settings…") }
                }
            }
            if let preview {
                previewCard(preview)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismissWindow(id: Self.windowID) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    join()
                } label: {
                    if joining { ProgressView().controlSize(.small) } else { Text("Join") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview == nil || joining)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onOpenURL { url in
            typed = url.absoluteString
            lookUp()
        }
        .onAppear {
            if JoinRequests.shared.takeElite() { target = .newElite }
            if let pending = JoinRequests.shared.take() {
                typed = pending.absoluteString
                lookUp()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: JoinRequests.arrived)) { _ in
            if JoinRequests.shared.takeElite() { target = .newElite }
            if let pending = JoinRequests.shared.take() {
                typed = pending.absoluteString
                lookUp()
            }
        }
    }

    private func previewCard(_ preview: InvitePreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.room.name)
                    .font(.title3.weight(.semibold))
                if !preview.room.description.isEmpty {
                    Text(preview.room.description)
                        .foregroundStyle(.secondary)
                }
                Text("\(preview.participants) \(preview.participants == 1 ? "person" : "people") · on \(invitation?.service.host ?? "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !preview.stations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(preview.stations, id: \.station) { station in
                        HStack(spacing: 6) {
                            StationBadge(number: station.station)
                            Text(station.label)
                            Text(station.kind)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            Divider()
            Picker("Join with", selection: $target) {
                Text("A new network with a BBC Model B").tag(Target.newModelB)
                Text("A new network with a BBC Master 128").tag(Target.newMaster)
                Text("A new network with an Elite over Econet player").tag(Target.newElite)
                ForEach(openNetworks, id: \.url) { session in
                    Text("“\(session.project.name)”, open now").tag(Target.network(session.url))
                }
            }
            if case .network(let url) = target, let session = NetworkSession.existing(url) {
                let taken = Set(preview.stations.map(\.station))
                let clashes = session.project.stations.filter { $0.stationNumber.map(taken.contains) ?? false }
                if !clashes.isEmpty {
                    Label("\(clashes.map { "\($0.name) (\($0.stationNumber ?? 0))" }.joined(separator: ", ")): someone in the network has that station number already. Once you've joined, MacBeeb offers a free one.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("Your name", text: $displayName, prompt: Text("Shown to the others"))
            if preview.room.allowsScreens {
                Toggle("Show my machine's screen to the others", isOn: $showScreen)
                    .toggleStyle(.checkbox)
                    .help("This network lets people share their screens: yours appears, live, on their canvas. You can change your mind later.")
            }
            if let otherService {
                Toggle("Use \(otherService.host ?? "") for my own networks too", isOn: $makeDefault)
                    .toggleStyle(.checkbox)
            }
            Text("Your machines' Econet joins the network; nothing else on your Mac is shared.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var openNetworks: [NetworkSession] {
        NetworkSession.open.values.filter { !$0.isInRoom }.sorted { $0.project.name < $1.project.name }
    }

    private func lookUp() {
        guard let invitation, !lookingUp else { return }
        lookingUp = true
        error = nil
        Task {
            defer { lookingUp = false }
            do {
                let api = RoomAPI(service: invitation.service)
                let info = try await api.serviceInfo()
                if let problem = info.incompatibility {
                    error = "\(invitation.service.host ?? ""): \(problem)."
                    return
                }
                preview = try await api.resolve(code: invitation.code, token: invitation.token)
            } catch let problem as RoomAPIError {
                error = problem.message
            } catch {
                self.error = "Couldn't reach \(invitation.service.host ?? "the service"). Check the Internet connection, and the address."
            }
        }
    }

    private func join() {
        guard let invitation, let preview else { return }
        joining = true
        NetworkSession.roomDisplayName = displayName.trimmingCharacters(in: .whitespaces)
        Task {
            defer { joining = false }
            do {
                let api = RoomAPI(service: invitation.service)
                let joined = try await api.join(roomId: preview.roomId, code: invitation.code, token: invitation.token,
                                                displayName: displayName.isEmpty ? "Guest" : displayName)
                let session: NetworkSession
                switch target {
                case .network(let url):
                    session = try NetworkSession.session(for: url)
                case .newModelB, .newMaster, .newElite:
                    session = try makeNetwork(for: preview, model: target == .newMaster ? .master128 : .modelB, elite: target == .newElite)
                }
                try session.enterRoom(service: invitation.service, roomId: preview.roomId, roomName: preview.room.name,
                                      joined: joined, shared: Set(session.project.stations.map(\.id)),
                                      showsScreens: showScreen && preview.room.allowsScreens)
                if makeDefault { InternetEconetService.current = invitation.service }
                NetworkStudioCommands.open(session.url, openWindow: openWindow)
                dismissWindow(id: Self.windowID)
            } catch let problem as RoomAPIError {
                error = problem.message
            } catch {
                self.error = "Couldn't join: \(error)"
            }
        }
    }

    /// A network of its own for the room: one machine, at a station number
    /// nobody in the room has, and a clock. An Elite player plays as a
    /// commander nobody in the room is (by its machines' names) and reports
    /// to the room's scoreboard.
    private func makeNetwork(for preview: InvitePreview, model: BBCMicro.Model, elite: Bool = false) throws -> NetworkSession {
        let taken = Set(preview.stations.map(\.station))
        let number = (1...253).first { !taken.contains($0) && $0 != 235 } ?? 1
        var project = NetworkProject(name: preview.room.name)
        var station: NetworkNode
        if elite {
            let names = Set(preview.stations.map { $0.label.replacingOccurrences(of: "Cmdr ", with: "").uppercased() })
            let commander = EliteOverEconet.commanderName(0, avoiding: names)
            let scoreboard = preview.stations.first { $0.label.hasPrefix(EliteOverEconet.scoreboardName) }?.station
            station = NetworkNode(kind: .station, name: "Cmdr \(commander.capitalized)", stationNumber: number,
                                  setup: EliteOverEconet.playerSetup, position: CanvasPoint(x: 0, y: 0))
            station.startupScript = EliteOverEconet.playerScript(commander: commander, scoreboard: scoreboard)
        } else {
            station = NetworkNode(kind: .station, name: model == .modelB ? "BBC \(number)" : "Master \(number)", stationNumber: number,
                                  setup: MachineSetup(model: model), position: CanvasPoint(x: 0, y: 0))
        }
        project.nodes = [station, .clock(at: CanvasPoint(x: 0, y: NetworkProject.rowSpacing))]
        project.workspace.tiles = project.stations.map(\.id)
        project.draft = true
        let url = RecentNetworks.newURL(named: preview.room.name)
        try NetworkPackage.save(project, to: url)
        return try NetworkSession.session(for: url)
    }
}

/// Invitation links (macbeeb://join…) waiting for the Join window.
@MainActor
final class JoinRequests {
    static let shared = JoinRequests()
    static let arrived = Notification.Name("MacBeebJoinRequest")
    private var pending: URL?
    /// File ▸ Add Remote Elite: join with an Elite player.
    private var wantsElite = false

    func requestElite() {
        wantsElite = true
        NotificationCenter.default.post(name: Self.arrived, object: nil)
    }

    func takeElite() -> Bool {
        defer { wantsElite = false }
        return wantsElite
    }

    func handle(_ url: URL) {
        pending = url
        NotificationCenter.default.post(name: Self.arrived, object: nil)
    }

    func take() -> URL? {
        defer { pending = nil }
        return pending
    }

    static func isJoinLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "macbeeb" && url.host?.lowercased() == "join"
    }
}

/// File ▸ Join Econet Network…
struct JoinRoomMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Join Econet Network…") { openWindow(id: JoinRoomView.windowID) }
            .keyboardShortcut("j", modifiers: [.command, .shift])
        Button("Add Remote Elite…") {
            JoinRequests.shared.requestElite()
            openWindow(id: JoinRoomView.windowID)
        }
        .help("Join an Elite over Econet game on the Internet with a player of your own: you'll need the invitation's code or link")
    }
}
