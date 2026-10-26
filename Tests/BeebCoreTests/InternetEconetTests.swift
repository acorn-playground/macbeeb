// Internet Econet's client: the binary protocol against the service's
// published test vectors, service addresses, and (with a service running:
// MACBEEB_ECONET_SERVICE=http://localhost:8787, from cloudflare-econet's
// `npm run dev`) two networks in a real room, over real WebSockets.

import Foundation
import Testing
@testable import BeebCore
@testable import BeebNetwork
import BeebROMs

struct EconetTrafficTests {
    struct Fixtures: Decodable {
        struct Valid: Decodable {
            var name, type, frame, encoded: String
            var final: Bool
            var stage: Int
            var transaction: UInt32
            var from, to: UInt8
        }
        struct Invalid: Decodable { var name, encoded, error: String }
        var valid: [Valid]
        var invalid: [Invalid]
    }

    static let fixtures: Fixtures = {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Resources/internet-econet/traffic.json")
        return try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }()

    static func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! })
    }

    @Test func decodesAndEncodesTheServicesVectors() throws {
        for f in Self.fixtures.valid {
            let message = try EconetTraffic.decode(Self.hex(f.encoded))
            let expected: EconetGatewayMessage = switch f.type {
            case "frame": .frame(transaction: f.transaction, stage: f.stage, final: f.final, bytes: [UInt8](Self.hex(f.frame)))
            case "noReply": .noReply(transaction: f.transaction, from: f.from, to: f.to)
            default: .broadcast(bytes: [UInt8](Self.hex(f.frame)))
            }
            #expect(message == expected, "\(f.name)")
            #expect(EconetTraffic.encode(message) == Self.hex(f.encoded), "\(f.name)")
        }
    }

    @Test func refusesWhatTheServiceRefuses() {
        for f in Self.fixtures.invalid {
            let expected: EconetTraffic.DecodeError = switch f.error {
            case "unsupportedVersion": .unsupportedVersion
            case "badAddress": .badAddress
            case "tooLarge": .tooLarge
            default: .malformed
            }
            #expect(throws: expected, "\(f.name)") { try EconetTraffic.decode(Self.hex(f.encoded)) }
        }
    }

    @Test func serviceAddresses() throws {
        #expect(try InternetEconetService.validate("econet.example.org").get().absoluteString == "https://econet.example.org")
        #expect(try InternetEconetService.validate(" https://econet.example.org/ ").get().absoluteString == "https://econet.example.org")
        #expect(try InternetEconetService.validate("http://localhost:8787").get().absoluteString == "http://localhost:8787")
        #expect(InternetEconetService.validate("http://econet.example.org") == .failure(.notSecure))
        #expect(InternetEconetService.validate("https://econet.example.org/v1") == .failure(.hasPath))
        #expect(InternetEconetService.origin(URL(string: "https://Econet.Example.org/x")!) == "https://econet.example.org")
    }
}

/// Two networks in a room on a real service, in real time.
struct InternetEconetLiveTests {
    static let service = ProcessInfo.processInfo.environment["MACBEEB_ECONET_SERVICE"].flatMap(URL.init(string:))

    /// Runs both networks in step with the wall clock until `done`.
    static func run(_ rigs: [EconetRig], seconds: Double, until done: () -> Bool) -> Bool {
        let start = Date()
        var cycles = 0
        while Date().timeIntervalSince(start) < seconds {
            if done() { return true }
            for rig in rigs { rig.run(cycles: 20_000) }
            cycles += 20_000
            let ahead = Double(cycles) / 2_000_000 - Date().timeIntervalSince(start)
            if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
        }
        return done()
    }

    @Test(.enabled(if: service != nil)) func oswordAcrossARealRoom() async throws {
        let api = RoomAPI(service: Self.service!)
        let created = try await api.createRoom(name: "MacBeeb live test", displayName: "Host")
        let preview = try await api.resolve(code: created.invite.code.lowercased())
        #expect(preview.room.name == "MacBeeb live test")
        let joined = try await api.join(roomId: created.roomId, code: created.invite.code, displayName: "Guest")

        let sides = [EconetRig([(.modelB, 1)]), EconetRig([(.modelB, 2)])]
        let links = [
            InternetEconetLink(api: api, roomId: created.roomId,
                               credentials: RoomCredentials(participantId: created.participantId, memberToken: created.memberToken),
                               claims: [StationClaim(station: 1, kind: "BBC Model B", label: "Host BBC")], shared: [1]),
            InternetEconetLink(api: api, roomId: created.roomId,
                               credentials: RoomCredentials(participantId: joined.participantId, memberToken: joined.memberToken),
                               claims: [StationClaim(station: 2, kind: "BBC Model B", label: "Guest BBC")], shared: [2]),
        ]
        for (side, link) in zip(sides, links) {
            side.bus.attach(device: link.gateway)
            link.connection.start()
        }
        defer {
            for link in links { link.connection.stop() }
            Task { try? await api.close(roomId: created.roomId, ownerToken: created.ownerToken) }
        }
        // Each sees the other's station.
        #expect(Self.run(sides, seconds: 10) { links[0].gateway.remoteStations == [2] && links[1].gateway.remoteStations == [1] })

        Self.run(sides, seconds: 2) { false }
        sides[1].runProgram(0, econetReceiver)
        #expect(Self.run(sides, seconds: 20) { sides[1].screen(0).contains("OPEN") }, "\(sides[1].screen(0))")
        sides[0].runProgram(0, econetSender(to: 2))
        #expect(Self.run(sides, seconds: 20) { sides[0].machines[0].screenText().contains { $0.hasPrefix("RESULT ") } }, "\(sides[0].screen(0))")
        #expect(sides[0].machines[0].screenText().contains { $0.hasPrefix("RESULT 0") }, "\(sides[0].screen(0))")
        #expect(Self.run(sides, seconds: 10) { sides[1].screen(0).contains("FROM 1 GOT HELLO ECONET") }, "\(sides[1].screen(0))")
    }

    static let invite = ProcessInfo.processInfo.environment["MACBEEB_ECONET_INVITE"]

    /// In a room someone else made (MACBEEB_ECONET_INVITE: its code), station
    /// 2 here listens for station 1 elsewhere: the browser version's, when
    /// web/tests/room-mixed.test.ts runs this.
    @Test(.enabled(if: service != nil && invite != nil)) func listensForAnotherClient() async throws {
        let api = RoomAPI(service: Self.service!)
        let preview = try await api.resolve(code: Self.invite!)
        let joined = try await api.join(roomId: preview.roomId, code: Self.invite!, displayName: "MacBeeb")
        let side = EconetRig([(.modelB, 2)])
        let link = InternetEconetLink(api: api, roomId: preview.roomId,
                                      credentials: RoomCredentials(participantId: joined.participantId, memberToken: joined.memberToken),
                                      claims: [StationClaim(station: 2, kind: "BBC Model B", label: "MacBeeb's BBC")], shared: [2])
        side.bus.attach(device: link.gateway)
        link.connection.start()
        defer { link.connection.stop() }
        #expect(Self.run([side], seconds: 20) { link.gateway.remoteStations.contains(1) })
        Self.run([side], seconds: 2) { false }
        side.runProgram(0, econetReceiver)
        #expect(Self.run([side], seconds: 20) { side.screen(0).contains("OPEN") }, "\(side.screen(0))")
        #expect(Self.run([side], seconds: 120) { side.screen(0).contains("FROM 1 GOT HELLO ECONET") }, "\(side.screen(0))")
        print("MacBeeb heard: FROM 1 GOT HELLO ECONET")
    }
}
