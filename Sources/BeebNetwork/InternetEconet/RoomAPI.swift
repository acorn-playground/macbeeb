import Foundation

// The service's HTTP API (cloudflare-econet's econet/docs/protocol.md): making,
// joining and managing rooms. Credentials only in Authorization headers.

public struct RoomView: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var locked: Bool
    /// Members may share their machines' screens (missing from older
    /// services).
    public var screenSharing: Bool?

    public var allowsScreens: Bool { screenSharing == true }
}

public struct ParticipantView: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var app: String
    public var owner: Bool
    public var online: Bool
    public var rttMs: Int?
}

public struct StationView: Codable, Sendable, Equatable, Identifiable {
    public var station: Int
    public var participantId: String
    public var kind: String
    public var label: String
    public var role: String
    public var online: Bool
    public var id: Int { station }
}

public struct Invite: Codable, Sendable, Equatable {
    public var id: String
    public var code: String
    public var url: String
    /// Nil: it never expires.
    public var expiresAt: String?
    /// Nil: any number of people can use it.
    public var maxUses: Int?

    /// The link's token: what follows /join/.
    public var token: String? { url.components(separatedBy: "/join/").last }

    /// When it stops working, if it does.
    public var expiry: Date? {
        expiresAt.flatMap { (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0)) ?? (try? Date($0, strategy: .iso8601)) }
    }
}

/// How long a new invitation lasts. One that lasts for good is for any
/// number of people too: a standing code for a network that's always there.
public enum InvitationLife: String, CaseIterable, Codable, Sendable, Identifiable {
    case hour, day, week, forever

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .hour: "1 hour"
        case .day: "1 day"
        case .week: "1 week"
        case .forever: "Never expires"
        }
    }

    /// Nil: no limit.
    var ttlSeconds: Int? {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        case .forever: nil
        }
    }

    var maxUses: Int? { self == .forever ? nil : 20 }

    /// As the service takes it: a number, or null for no limit.
    var body: [String: Any] {
        ["ttlSeconds": ttlSeconds.map { $0 as Any } ?? NSNull(), "maxUses": maxUses.map { $0 as Any } ?? NSNull()]
    }
}

public struct CreatedRoom: Codable, Sendable {
    public var roomId: String
    public var participantId: String
    public var ownerToken: String
    public var memberToken: String
    public var invite: Invite
}

public struct InvitePreview: Codable, Sendable, Equatable {
    public var roomId: String
    public var room: RoomView
    public var participants: Int
    public var stations: [PreviewStation]
    /// Nil: it never expires.
    public var inviteExpiresAt: String?

    public struct PreviewStation: Codable, Sendable, Equatable {
        public var station: Int
        public var kind: String
        public var label: String
        public var role: String
    }
}

public struct JoinedRoom: Codable, Sendable {
    public var participantId: String
    public var memberToken: String
    public var room: RoomView
}

public struct RoomInfo: Codable, Sendable {
    public var room: RoomView
    public var participantId: String
    public var owner: Bool
    public var participants: [ParticipantView]
    public var stations: [StationView]
}

/// What went wrong, as the service said it (fit to show).
public struct RoomAPIError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var code: String
    public var message: String
    public var description: String { message }
}

public struct RoomAPI: Sendable {
    public let service: URL
    let session: URLSession

    public init(service: URL, session: URLSession = .shared) {
        self.service = service
        self.session = session
    }

    static let client = ["app": "MacBeeb", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]

    private func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, token: String? = nil,
                                       as type: T.Type) async throws -> T {
        var request = URLRequest(url: service.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let problem = try? JSONDecoder().decode(Problem.self, from: data) {
                throw RoomAPIError(status: status, code: problem.error.code, message: problem.error.message)
            }
            throw RoomAPIError(status: status, code: "http\(status)", message: "The service answered \(status)")
        }
        if T.self == Empty.self { return Empty() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct Empty: Decodable {}

    struct Problem: Decodable {
        var error: Detail
        struct Detail: Decodable { var code: String; var message: String }
    }

    public func serviceInfo() async throws -> ServiceInfo {
        try await request("GET", ".well-known/acorn-econet", as: ServiceInfo.self)
    }

    /// A new room, with an invitation lasting `invitation`.
    public func createRoom(name: String, description: String = "", displayName: String, screenSharing: Bool = false,
                           invitation: InvitationLife = .day) async throws -> CreatedRoom {
        try await request("POST", "v1/rooms", body: ["name": name, "description": description, "displayName": displayName,
                                                     "client": Self.client, "screenSharing": screenSharing, "invite": invitation.body],
                          as: CreatedRoom.self)
    }

    /// A code (as typed) or a link's token: the room it's for, without
    /// joining.
    public func resolve(code: String? = nil, token: String? = nil) async throws -> InvitePreview {
        var body: [String: Any] = [:]
        if let code { body["code"] = code }
        if let token { body["token"] = token }
        return try await request("POST", "v1/invites/resolve", body: body, as: InvitePreview.self)
    }

    public func join(roomId: String, code: String? = nil, token: String? = nil, displayName: String) async throws -> JoinedRoom {
        var body: [String: Any] = ["displayName": displayName, "client": Self.client]
        if let code { body["code"] = code }
        if let token { body["token"] = token }
        return try await request("POST", "v1/rooms/\(roomId)/join", body: body, as: JoinedRoom.self)
    }

    public func ticket(roomId: String, memberToken: String) async throws -> String {
        struct Ticket: Decodable { var ticket: String }
        return try await request("POST", "v1/rooms/\(roomId)/tickets", token: memberToken, as: Ticket.self).ticket
    }

    public func info(roomId: String, memberToken: String) async throws -> RoomInfo {
        try await request("GET", "v1/rooms/\(roomId)", token: memberToken, as: RoomInfo.self)
    }

    public func update(roomId: String, ownerToken: String, name: String? = nil, locked: Bool? = nil,
                       screenSharing: Bool? = nil) async throws -> RoomView {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let locked { body["locked"] = locked }
        if let screenSharing { body["screenSharing"] = screenSharing }
        return try await request("PATCH", "v1/rooms/\(roomId)", body: body, token: ownerToken, as: RoomView.self)
    }

    public func newInvite(roomId: String, ownerToken: String, lasting life: InvitationLife = .day) async throws -> Invite {
        try await request("POST", "v1/rooms/\(roomId)/invites", body: life.body, token: ownerToken, as: Invite.self)
    }

    public func revokeInvite(roomId: String, ownerToken: String, inviteId: String) async throws {
        _ = try await request("DELETE", "v1/rooms/\(roomId)/invites/\(inviteId)", token: ownerToken, as: Empty.self)
    }

    public func remove(roomId: String, ownerToken: String, participantId: String) async throws {
        _ = try await request("DELETE", "v1/rooms/\(roomId)/participants/\(participantId)", token: ownerToken, as: Empty.self)
    }

    public func close(roomId: String, ownerToken: String) async throws {
        _ = try await request("DELETE", "v1/rooms/\(roomId)", token: ownerToken, as: Empty.self)
    }

    public func leave(roomId: String, memberToken: String) async throws {
        _ = try await request("POST", "v1/rooms/\(roomId)/leave", token: memberToken, as: Empty.self)
    }

    public func screenTicket(roomId: String, memberToken: String) async throws -> String {
        struct Ticket: Decodable { var ticket: String }
        return try await request("POST", "v1/rooms/\(roomId)/screen-tickets", token: memberToken, as: Ticket.self).ticket
    }

    /// The room's screens socket, for a ticket.
    public func screensURL(roomId: String, ticket: String) -> URL {
        var components = URLComponents(url: service.appendingPathComponent("v1/rooms/\(roomId)/screens"), resolvingAgainstBaseURL: false)!
        components.scheme = service.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        return components.url!
    }

    /// The room's socket, for a ticket.
    public func connectURL(roomId: String, ticket: String) -> URL {
        var components = URLComponents(url: service.appendingPathComponent("v1/rooms/\(roomId)/connect"), resolvingAgainstBaseURL: false)!
        components.scheme = service.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        return components.url!
    }
}
