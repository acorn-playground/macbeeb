import BeebCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A station of this network's, as the room's told of it.
public struct StationClaim: Sendable, Equatable, Hashable {
    public var station: Int
    public var kind: String
    public var label: String
    /// "station", "fileServer" or "printServer".
    public var role: String

    public init(station: Int, kind: String, label: String, role: String = "station") {
        self.station = station
        self.kind = kind
        self.label = label
        self.role = role
    }
}

/// One network's connection to its room: hello, its stations' leases, the
/// gateway's traffic both ways, round-trip times, and reconnecting (with
/// backoff and jitter) when it's lost. Its callbacks come on its own queue.
public final class RoomConnection: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case connecting
        case connected
        /// Lost: trying again in a few seconds.
        case reconnecting(attempt: Int)
        /// Over: the room closed, this member was removed, or the app's too
        /// old. Not retried.
        case ended(String)
        case stopped
    }

    public struct Snapshot: Sendable, Equatable {
        public var state: State = .connecting
        public var room: RoomView?
        public var participantId: String?
        public var owner = false
        public var participants: [ParticipantView] = []
        public var stations: [StationView] = []
        /// This connection's round trip to the service.
        public var rttMs: Int?
        /// Stations the room refused (another member has the number).
        public var refused: [Int: String] = [:]
        /// The last problem worth showing.
        public var problem: String?
    }

    public let api: RoomAPI
    public let roomId: String
    private let credentials: RoomCredentials
    private let queue = DispatchQueue(label: "MacBeeb room connection")
    private var claims: [StationClaim]
    private var task: URLSessionWebSocketTask?
    private var snapshot = Snapshot()
    private var stopped = false
    private var attempt = 0
    private var pingSent: Date?
    private var heartbeat: DispatchSourceTimer?

    /// Called with each change (on the connection's queue).
    public var onChange: (@Sendable (Snapshot) -> Void)?
    /// Traffic for this network's gateway.
    public var onTraffic: (@Sendable (EconetGatewayMessage) -> Void)?

    public init(api: RoomAPI, roomId: String, credentials: RoomCredentials, claims: [StationClaim]) {
        self.api = api
        self.roomId = roomId
        self.credentials = credentials
        self.claims = claims
    }

    public func start() {
        queue.async { self.connect() }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.heartbeat?.cancel()
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            self.update { $0.state = .stopped }
        }
    }

    /// The gateway's traffic, out to the room.
    public func send(_ message: EconetGatewayMessage) {
        let data = EconetTraffic.encode(message)
        queue.async {
            self.task?.send(.data(data)) { _ in }
        }
    }

    /// This network's stations changed: lease new ones, give up old ones.
    public func setClaims(_ new: [StationClaim]) {
        queue.async {
            let old = self.claims
            self.claims = new
            guard self.snapshot.state == .connected else { return }
            for claim in new where !old.contains(claim) { self.sendClaim(claim) }
            for claim in old where !new.contains(where: { $0.station == claim.station }) {
                self.sendJSON(["type": "release", "station": claim.station])
            }
            self.update { snapshot in
                for station in snapshot.refused.keys where !new.contains(where: { $0.station == station }) {
                    snapshot.refused[station] = nil
                }
            }
        }
    }

    // MARK: Connecting (on the queue)

    private func connect() {
        guard !stopped else { return }
        update { $0.state = self.attempt == 0 ? .connecting : .reconnecting(attempt: self.attempt) }
        Task {
            do {
                let ticket = try await api.ticket(roomId: roomId, memberToken: credentials.memberToken)
                queue.async { self.open(ticket: ticket) }
            } catch let error as RoomAPIError where error.status == 403 || error.status == 404 {
                queue.async { self.end(error.status == 404 ? "The room has closed" : "You're no longer a member of this room") }
            } catch {
                queue.async { self.retry(problem: "Can't reach the Internet Econet service") }
            }
        }
    }

    private func open(ticket: String) {
        guard !stopped else { return }
        let task = URLSession.shared.webSocketTask(with: api.connectURL(roomId: roomId, ticket: ticket))
        task.maximumMessageSize = 1 << 20
        self.task = task
        task.resume()
        sendJSON(["type": "hello", "protocolVersion": ServiceInfo.protocolVersion, "client": RoomAPI.client])
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === task else { return }
                switch result {
                case .success(.string(let text)):
                    self.control(text)
                    self.receive(task)
                case .success(.data(let data)):
                    if let message = try? EconetTraffic.decode(data) { self.onTraffic?(message) }
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure:
                    self.lost(task)
                }
            }
        }
    }

    private func lost(_ task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        self.task = nil
        heartbeat?.cancel()
        switch task.closeCode.rawValue {
        case 4001: end("The room's host removed you")
        case 4002: end("The room has closed")
        case 4003: end("This room was opened somewhere else")
        case 4004: end("This MacBeeb is too old for the service: update it")
        default: retry(problem: "Lost the connection to the room")
        }
    }

    private func retry(problem: String) {
        guard !stopped else { return }
        attempt += 1
        // 1, 2, 4… up to 30 seconds, give or take a fifth.
        let base = min(30, pow(2, Double(min(attempt, 6) - 1)))
        let delay = base * Double.random(in: 0.8...1.2)
        update {
            $0.state = .reconnecting(attempt: self.attempt)
            $0.problem = problem
            for i in $0.participants.indices { $0.participants[i].online = $0.participants[i].id == self.credentials.participantId ? false : $0.participants[i].online }
        }
        queue.asyncAfter(deadline: .now() + delay) { self.connect() }
    }

    private func end(_ reason: String) {
        stopped = true
        heartbeat?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        update { $0.state = .ended(reason) }
    }

    // MARK: Control messages

    private func control(_ text: String) {
        if text == "pong" {
            if let sent = pingSent {
                let rtt = Int(Date().timeIntervalSince(sent) * 1000)
                pingSent = nil
                update { $0.rttMs = rtt }
                sendJSON(["type": "status", "rttMs": rtt])
            }
            return
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            guard let value = object[key], let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
        switch type {
        case "welcome":
            attempt = 0
            update {
                $0.state = .connected
                $0.problem = nil
                $0.participantId = object["participantId"] as? String
                $0.owner = object["owner"] as? Bool ?? false
                $0.room = decode("room", RoomView.self)
                $0.participants = decode("participants", [ParticipantView].self) ?? []
                $0.stations = decode("stations", [StationView].self) ?? []
                $0.refused = [:]
            }
            for claim in claims { sendClaim(claim) }
            startHeartbeat()
        case "room":
            if let room = decode("room", RoomView.self) { update { $0.room = room } }
        case "participants":
            if let list = decode("participants", [ParticipantView].self) { update { $0.participants = list } }
        case "stations":
            if let list = decode("stations", [StationView].self) { update { $0.stations = list } }
        case "claimed":
            if let station = object["station"] as? Int { update { $0.refused[station] = nil } }
        case "error":
            let message = object["message"] as? String ?? "The service refused something"
            if let station = object["station"] as? Int {
                update { $0.refused[station] = message }
            } else {
                update { $0.problem = message }
            }
        case "closing":
            switch object["reason"] as? String {
            case "removed": end("The room's host removed you")
            case "replaced": end("This room was opened somewhere else")
            default: end("The room has closed")
            }
        default:
            break
        }
    }

    private func sendClaim(_ claim: StationClaim) {
        sendJSON(["type": "claim", "station": claim.station, "kind": claim.kind, "label": claim.label, "role": claim.role])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    /// A ping every 20 seconds (answered by the service without waking the
    /// room), timed for the room's latency display.
    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, let task = self.task else { return }
            self.pingSent = Date()
            task.send(.string("ping")) { _ in }
        }
        heartbeat = timer
        timer.resume()
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        change(&snapshot)
        onChange?(snapshot)
    }
}
