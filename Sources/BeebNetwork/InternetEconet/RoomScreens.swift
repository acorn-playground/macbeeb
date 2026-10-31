import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A room's screens connection: apart from its Econet (its own WebSocket,
/// to its own object on the service), so an image never waits in front of
/// a frame. Images go one at a time: while one's sending, a newer one
/// replaces any waiting, and older ones are dropped, never queued.
public final class RoomScreens: @unchecked Sendable {
    public let api: RoomAPI
    public let roomId: String
    private let memberToken: String
    private let queue = DispatchQueue(label: "MacBeeb room screens", qos: .utility)
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private var attempt = 0
    private var sending = false
    private var waiting: (station: UInt8, jpeg: Data, width: Int, height: Int)?

    /// A screen from another member: its station and JPEG (on the
    /// connection's queue).
    public var onScreen: (@Sendable (UInt8, Data) -> Void)?

    public init(api: RoomAPI, roomId: String, memberToken: String) {
        self.api = api
        self.roomId = roomId
        self.memberToken = memberToken
    }

    public func start() {
        queue.async { self.connect() }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
        }
    }

    /// One of this member's machines' screens, as JPEG.
    public func send(station: UInt8, jpeg: Data, width: Int, height: Int) {
        queue.async {
            self.waiting = (station, jpeg, width, height)
            self.sendNext()
        }
    }

    private func sendNext() {
        guard !sending, let task, let next = waiting else { return }
        waiting = nil
        sending = true
        var message = Data([1, 16, next.station, 1, UInt8(next.width >> 8), UInt8(next.width & 0xFF),
                            UInt8(next.height >> 8), UInt8(next.height & 0xFF)])
        message.append(next.jpeg)
        task.send(.data(message)) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                self.sendNext()
            }
        }
    }

    private func connect() {
        guard !stopped else { return }
        Task {
            do {
                let ticket = try await api.screenTicket(roomId: roomId, memberToken: memberToken)
                queue.async { self.open(ticket: ticket) }
            } catch let error as RoomAPIError where error.status == 403 || error.status == 404 {
                // Not allowed (or no room): stays off until it's started again.
                queue.async { self.stopped = true }
            } catch {
                queue.async { self.retry() }
            }
        }
    }

    private func open(ticket: String) {
        guard !stopped else { return }
        let task = URLSession.shared.webSocketTask(with: api.screensURL(roomId: roomId, ticket: ticket))
        task.maximumMessageSize = 1 << 17
        self.task = task
        sending = false
        task.resume()
        attempt = 0
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === task else { return }
                switch result {
                case .success(.data(let data)):
                    if data.count > 8, data[data.startIndex + 1] == 16 {
                        self.onScreen?(data[data.startIndex + 2], data.dropFirst(8))
                    }
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure:
                    self.task = nil
                    // Sharing turned off, or removed: done.
                    if [4001, 4005].contains(task.closeCode.rawValue) {
                        self.stopped = true
                    } else {
                        self.retry()
                    }
                }
            }
        }
    }

    private func retry() {
        guard !stopped else { return }
        attempt += 1
        let delay = min(30, pow(2, Double(min(attempt, 6) - 1))) * Double.random(in: 0.8...1.2)
        queue.asyncAfter(deadline: .now() + delay) { self.connect() }
    }
}
