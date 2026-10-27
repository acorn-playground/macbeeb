import BeebNetwork
import CoreGraphics
import Foundation
import ImageIO

/// A network in an Internet Econet room: sharing it (as its host), joining
/// one, and keeping the room told of its stations.
extension NetworkSession {
    /// Where room credentials are kept: the Keychain, except in self-tests.
    static let credentialStore: RoomCredentialStore = LaunchScreen.isSelfTest ? MemoryCredentialStore() : KeychainCredentialStore()

    /// The name others in a room see for this person.
    static var roomDisplayName: String {
        get { UserDefaults.standard.string(forKey: "MacBeebEconetDisplayName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "MacBeebEconetDisplayName") }
    }

    var isInRoom: Bool { project.internetRoom != nil }

    /// What each machine is, for the room: shared machines as they are,
    /// others keeping their numbers but marked.
    func roomClaims(shared: Set<UUID>) -> (claims: [StationClaim], sharedStations: Set<UInt8>) {
        var claims: [StationClaim] = []
        var sharedStations: Set<UInt8> = []
        for node in project.stations {
            guard let number = node.stationNumber, (1...254).contains(number) else { continue }
            let role = switch node.kind {
            case .fileServer: "fileServer"
            case .printServer: "printServer"
            default: "station"
            }
            let isShared = shared.contains(node.id)
            if isShared { sharedStations.insert(UInt8(number)) }
            claims.append(StationClaim(station: number, kind: node.setup?.model.displayName ?? "BBC Micro",
                                       label: isShared ? node.name : "\(node.name) (not shared)", role: role))
        }
        return (claims, sharedStations)
    }

    /// Opened with a room: back into it.
    func connectToRoomIfLinked() {
        guard let link = project.internetRoom,
              let credentials = Self.credentialStore.credentials(service: link.service, roomId: link.roomId) else { return }
        startRoomLink(link, credentials: credentials)
    }

    private func startRoomLink(_ link: InternetRoomLink, credentials: RoomCredentials) {
        internet?.stop()
        let (claims, shared) = roomClaims(shared: Set(link.shared))
        lastClaims = claims
        let internet = InternetEconetLink(api: RoomAPI(service: link.service), roomId: link.roomId, credentials: credentials,
                                          claims: claims, shared: shared)
        internet.onChange = { [weak self] snapshot in
            Task { @MainActor in self?.roomChanged(snapshot) }
        }
        self.internet = internet
        internet.start(on: runtime.network)
    }

    private func roomChanged(_ snapshot: RoomConnection.Snapshot) {
        room = snapshot
        updateScreens()
        // The room's name, as the host changes it.
        if let name = snapshot.room?.name, project.internetRoom?.roomName != name {
            update { $0.internetRoom?.roomName = name }
        }
        if case .ended = snapshot.state, let link = project.internetRoom, !link.hosting {
            // Removed, or the room's gone: it's no longer in one.
            Self.credentialStore.remove(service: link.service, roomId: link.roomId)
        }
    }

    /// The machines changed: tell the room.
    func roomClaimsMayHaveChanged() {
        guard let internet, let link = project.internetRoom else { return }
        let (claims, shared) = roomClaims(shared: Set(link.shared))
        guard claims != lastClaims || shared != internet.gateway.sharedStations else { return }
        lastClaims = claims
        internet.update(claims: claims, shared: shared)
    }

    // MARK: Hosting

    /// Makes a private room on `service` and shares `shared` into it;
    /// `screenSharing`: members may show their screens, `showsScreens`: this
    /// network shows its; `invitation`: how long its first invitation lasts.
    func share(on service: URL, name: String, shared: Set<UUID>, screenSharing: Bool = false, showsScreens: Bool = false,
               invitation: InvitationLife = .day) async throws {
        let api = RoomAPI(service: service)
        let created = try await api.createRoom(name: name, displayName: Self.roomDisplayName.isEmpty ? "Host" : Self.roomDisplayName,
                                               screenSharing: screenSharing, invitation: invitation)
        let credentials = RoomCredentials(participantId: created.participantId, memberToken: created.memberToken,
                                          ownerToken: created.ownerToken)
        try Self.credentialStore.save(credentials, service: service, roomId: created.roomId)
        var link = InternetRoomLink(service: service, roomId: created.roomId, roomName: name, hosting: true,
                                    shared: project.stations.map(\.id).filter { shared.contains($0) })
        link.showsScreens = showsScreens
        update { $0.internetRoom = link }
        currentInvite = created.invite
        startRoomLink(link, credentials: credentials)
    }

    /// Joined a room (the join sheet has done the asking): into it.
    func enterRoom(service: URL, roomId: String, roomName: String, joined: JoinedRoom, shared: Set<UUID>,
                   showsScreens: Bool = false) throws {
        let credentials = RoomCredentials(participantId: joined.participantId, memberToken: joined.memberToken)
        try Self.credentialStore.save(credentials, service: service, roomId: roomId)
        var link = InternetRoomLink(service: service, roomId: roomId, roomName: roomName, hosting: false,
                                    shared: project.stations.map(\.id).filter { shared.contains($0) })
        link.showsScreens = showsScreens
        update { $0.internetRoom = link }
        startRoomLink(link, credentials: credentials)
    }

    /// Which machines are shared.
    func setShared(_ shared: Set<UUID>) {
        let ordered = project.stations.map(\.id).filter { shared.contains($0) }
        update { $0.internetRoom?.shared = ordered }
    }

    private var ownerToken: String? {
        guard let link = project.internetRoom else { return nil }
        return Self.credentialStore.credentials(service: link.service, roomId: link.roomId)?.ownerToken
    }

    private var roomAPI: RoomAPI? { project.internetRoom.map { RoomAPI(service: $0.service) } }

    func newInvitation(lasting life: InvitationLife = .day) async throws {
        guard let api = roomAPI, let link = project.internetRoom, let owner = ownerToken else { return }
        currentInvite = try await api.newInvite(roomId: link.roomId, ownerToken: owner, lasting: life)
    }

    /// Withdraws the invitation shown: its link and code stop working.
    func withdrawInvitation() async throws {
        guard let api = roomAPI, let link = project.internetRoom, let owner = ownerToken, let invite = currentInvite else { return }
        try await api.revokeInvite(roomId: link.roomId, ownerToken: owner, inviteId: invite.id)
        currentInvite = nil
    }

    func setRoomLocked(_ locked: Bool) async throws {
        guard let api = roomAPI, let link = project.internetRoom, let owner = ownerToken else { return }
        _ = try await api.update(roomId: link.roomId, ownerToken: owner, locked: locked)
    }

    func removeFromRoom(_ participantId: String) async throws {
        guard let api = roomAPI, let link = project.internetRoom, let owner = ownerToken else { return }
        try await api.remove(roomId: link.roomId, ownerToken: owner, participantId: participantId)
    }

    /// The host closes the room for everyone; a guest leaves it. Either way
    /// the network's local again.
    func leaveRoom() async {
        guard let link = project.internetRoom else { return }
        let api = RoomAPI(service: link.service)
        let credentials = Self.credentialStore.credentials(service: link.service, roomId: link.roomId)
        stopScreens()
        internet?.stop()
        internet = nil
        if let credentials {
            if let owner = credentials.ownerToken {
                try? await api.close(roomId: link.roomId, ownerToken: owner)
            } else {
                try? await api.leave(roomId: link.roomId, memberToken: credentials.memberToken)
            }
        }
        Self.credentialStore.remove(service: link.service, roomId: link.roomId)
        update { $0.internetRoom = nil }
        room = nil
        currentInvite = nil
    }

    // MARK: Station numbers

    /// A machine whose station number another member already has in the
    /// room, and a number it could have instead.
    struct RoomConflict: Identifiable, Equatable {
        var node: UUID
        var name: String
        var station: Int
        var suggestion: Int?
        var isOn: Bool
        var id: UUID { node }
    }

    var roomConflicts: [RoomConflict] {
        guard let refused = room?.refused, !refused.isEmpty else { return [] }
        return refused.keys.sorted().compactMap { station in
            guard let node = project.stations.first(where: { $0.stationNumber == station }) else { return nil }
            return RoomConflict(node: node.id, name: node.name, station: station, suggestion: freeRoomStation(for: node.kind),
                                isOn: controllers[node.id] != nil)
        }
    }

    /// A number nobody in the room has and this network isn't using: 254
    /// down for a file server, 235 down for a printer server (their usual
    /// numbers), else the lowest, keeping those two free.
    func freeRoomStation(for kind: NetworkNode.Kind) -> Int? {
        let taken = Set(room?.stations.map(\.station) ?? []).union(project.nodes.compactMap(\.stationNumber))
        let order: [Int] = switch kind {
        case .fileServer: Array((1...254).reversed())
        case .printServer: Array((1...235).reversed()) + Array(236...253)
        default: Array(1...253).filter { $0 != 235 }
        }
        return order.first { !taken.contains($0) }
    }

    /// Gives a machine another station number for the room. Its network
    /// interface takes its number when it starts, so a machine that's on
    /// starts again (its memory is lost; its discs stay).
    func renumberForRoom(_ id: UUID, to number: Int) -> String? {
        renumber(id, to: number)
    }

    // MARK: Screens

    /// Whether this network shows its shared machines' screens.
    var showsScreens: Bool { project.internetRoom?.showsScreens == true }

    func setShowsScreens(_ on: Bool) {
        update { $0.internetRoom?.showsScreens = on }
        updateScreens()
    }

    /// The host allows screen sharing, or doesn't.
    func setScreenSharingAllowed(_ allowed: Bool) async throws {
        guard let api = roomAPI, let link = project.internetRoom, let owner = ownerToken else { return }
        _ = try await api.update(roomId: link.roomId, ownerToken: owner, screenSharing: allowed)
    }

    /// Screens on when the room allows them (to see others'), sending this
    /// network's when it shows them; off otherwise.
    func updateScreens() {
        let allowed = room?.state == .connected && room?.room?.allowsScreens == true
        guard allowed, let link = project.internetRoom,
              let credentials = Self.credentialStore.credentials(service: link.service, roomId: link.roomId) else {
            stopScreens()
            return
        }
        if screens == nil {
            let screens = RoomScreens(api: RoomAPI(service: link.service), roomId: link.roomId, memberToken: credentials.memberToken)
            screens.onScreen = { [weak self] station, jpeg in
                guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
                Task { @MainActor in self?.remoteScreens[Int(station)] = image }
            }
            self.screens = screens
            screens.start()
        }
        if showsScreens {
            if screenTimer == nil {
                screenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sendScreens() }
                }
            }
        } else {
            screenTimer?.invalidate()
            screenTimer = nil
        }
    }

    func stopScreens() {
        screenTimer?.invalidate()
        screenTimer = nil
        screens?.stop()
        screens = nil
        if !remoteScreens.isEmpty { remoteScreens = [:] }
    }

    /// Each shared machine's latest picture, half size, as JPEG: made off
    /// the main thread (and nowhere near the network's), one at a time
    /// per machine.
    private func sendScreens() {
        guard let screens, let link = project.internetRoom else { return }
        for node in project.stations where link.shared.contains(node.id) {
            guard let number = node.stationNumber, (1...254).contains(number), !sendingScreens.contains(node.id),
                  let frame = controllers[node.id]?.host.frame else { continue }
            sendingScreens.insert(node.id)
            let id = node.id
            DispatchQueue.global(qos: .utility).async {
                if let image = ThumbnailCache.halfSize(frame.pixels), let jpeg = Self.jpeg(image) {
                    screens.send(station: UInt8(number), jpeg: jpeg, width: image.width, height: image.height)
                }
                Task { @MainActor [weak self] in self?.sendingScreens.remove(id) }
            }
        }
    }

    nonisolated static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Stations of other members, for the canvas.
    var remoteStations: [StationView] {
        guard let room, let me = room.participantId else { return [] }
        return room.stations.filter { $0.participantId != me }
    }

    func participant(_ id: String) -> ParticipantView? {
        room?.participants.first { $0.id == id }
    }
}
