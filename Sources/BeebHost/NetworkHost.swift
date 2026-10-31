import BeebCore
import BeebPrint
import Foundation
import Synchronization

/// Runs a network's machines together on one thread, in lockstep: every
/// station runs to the same point in emulated time before any goes further,
/// so none can get ahead of another and miss what it sends. Each station is
/// an `EmulatorHost` without a thread of its own, so windows, debuggers and
/// agents use it just as they use a standalone machine's.
public final class NetworkHost: @unchecked Sendable {
    /// What the network's thread is told to do.
    enum Command {
        case add(UUID, EmulatorHost)
        case remove(UUID)
        /// The Econet's clock rate (bits a second), or nil for none.
        case setClock(Int?)
        /// A device on the line (an Internet gateway), or off it.
        case attachDevice(EconetLineDevice)
        case detachDevice(EconetLineDevice)
    }

    /// The network's state as of its last quantum.
    public struct Status: Sendable, Equatable {
        /// Emulated 2MHz cycles since the network started.
        public var cycles: UInt64 = 0
        /// Emulated time against wall time over the last second or so (1 is
        /// real time).
        public var speed: Double = 0
        /// The whole network is paused, by the user or a debugger stop.
        public var paused = false
        /// The stations stopped by their debuggers.
        public var stoppedStations: Set<UUID> = []
        /// What each Econet station has put on the line, by station number.
        public var traffic: [UInt8: Traffic] = [:]
        /// The threads the network's running on.
        public var threads = 1

        public init() {}
    }

    /// A station's transmissions so far.
    public struct Traffic: Sendable, Equatable {
        public var bytes = 0
        /// Each frame ends with two check bytes.
        var checkBytes = 0
        public var frames: Int { checkBytes / 2 }
        /// Byte-times spoiled by collisions.
        public var collisions = 0
    }

    public let sampleRate: Int
    private let commands = Mutex<[Command]>([])
    private let pausedFlag = Atomic<Bool>(false)
    private let speedLimitedFlag = Atomic<Bool>(true)
    private let pauseOnBreakpointFlag = Atomic<Bool>(true)
    private let running = Atomic<Bool>(true)
    private let latestStatus = Mutex(Status())
    /// The station whose sound is heard, which paces the network while
    /// it plays.
    private let audioStation = Mutex<UUID?>(nil)
    private var thread: Thread?

    /// Emulated cycles each station runs before the others catch up:
    /// short enough, with an Econet, for the line's timing.
    public let quantum: Int
    /// The network's Econet, if its machines have one. Used only on the
    /// network's thread.
    let bus: EconetBus?
    /// Sees every symbol on the line (on the network's thread).
    public var lineObserver: ((EconetLineEvent) -> Void)?
    private var traffic: [UInt8: Traffic] = [:]

    /// The frames on the line, as the inspector and agents read them.
    private let trace = EconetTrace()
    private let traceLock = NSLock()

    /// Frames after `id` (all kept, if nil), newest last.
    public func frames(after id: Int? = nil, limit: Int = .max) -> [EconetFrame] {
        traceLock.withLock { trace.frames(after: id, limit: limit) }
    }

    /// Frames seen since the trace began (including any no longer kept).
    public var frameCount: Int { traceLock.withLock { trace.count } }

    public var isTracing: Bool { traceLock.withLock { trace.recording } }

    public func setTracing(_ on: Bool) {
        traceLock.withLock { trace.recording = on }
    }

    public func clearTrace() {
        traceLock.withLock { trace.clear() }
    }

    private func observe(_ event: EconetLineEvent) {
        traceLock.withLock { trace.observe(event) }
        switch event.symbol {
        case .byte: traffic[event.station, default: Traffic()].bytes += 1
        case .check: traffic[event.station, default: Traffic()].checkBytes += 1
        default: break
        }
        if event.collided {
            traffic[event.station, default: Traffic()].collisions += 1
        }
        lineObserver?(event)
    }

    public init(sampleRate: Int = 48_000, quantum: Int = 2_000, econetClockRate: Int?? = nil) {
        self.sampleRate = sampleRate
        if let clock = econetClockRate {
            let bus = EconetBus(clockRate: clock)
            self.bus = bus
            self.quantum = bus.delay
        } else {
            bus = nil
            self.quantum = quantum
        }
        bus?.observer = { [unowned self] event in observe(event) }
    }

    /// Changes the Econet's clock (nil takes it away).
    public func setClock(_ rate: Int?) {
        commands.withLock { $0.append(.setClock(rate)) }
    }

    /// Puts a device (an Internet gateway) on the network's line, from its
    /// next quantum. Nothing happens without an Econet.
    public func attach(device: EconetLineDevice) {
        commands.withLock { $0.append(.attachDevice(device)) }
    }

    public func detach(device: EconetLineDevice) {
        commands.withLock { $0.append(.detachDevice(device)) }
    }

    deinit {
        stop()
    }

    /// A new station, run by this network from its next quantum. Don't
    /// `start` it: the network runs it.
    public func addStation(id: UUID, discDriveSounds: (@Sendable (BBCMicro.Model) -> DiscDriveSounds?)? = nil,
                           discDriveSoundsOn: Bool = true, keepsRewind: Bool = false,
                           printer: (name: String, jobs: @Sendable (PrintJob) -> Void)? = nil,
                           makeMachine: @escaping @Sendable () -> BBCMicro) -> EmulatorHost {
        let host = EmulatorHost(sampleRate: sampleRate, discDriveSounds: discDriveSounds,
                                discDriveSoundsOn: discDriveSoundsOn, makeMachine: makeMachine)
        if let printer {
            host.printerName = printer.name
            host.printJobs = printer.jobs
        }
        host.isNetworkStation = true
        host.network = self
        host.keepsRewind = keepsRewind
        commands.withLock { $0.append(.add(id, host)) }
        return host
    }

    /// Takes a station off the network: it stops running.
    public func removeStation(id: UUID) {
        commands.withLock { $0.append(.remove(id)) }
    }

    public func start() {
        guard thread == nil else { return }
        let thread = Thread { [unowned self] in self.threadMain() }
        thread.name = "BBC Micro network"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        // Not started (a test's): its workers stop here.
        if thread == nil { workers.stop() }
    }

    /// Pauses every station together: no emulated time passes anywhere,
    /// so nothing on the network times out.
    public func setPaused(_ paused: Bool) {
        pausedFlag.store(paused, ordering: .releasing)
    }

    public var isPaused: Bool { pausedFlag.load(ordering: .acquiring) }

    /// Real time (true), or as fast as the Mac can go.
    public func setSpeedLimited(_ limited: Bool) {
        speedLimitedFlag.store(limited, ordering: .releasing)
    }

    /// Whether a debugger stop on one station pauses the whole network (the
    /// default), or lets the others run on and perhaps time out.
    public func setPauseOnBreakpoint(_ on: Bool) {
        pauseOnBreakpointFlag.store(on, ordering: .releasing)
    }

    public var pausesOnBreakpoint: Bool { pauseOnBreakpointFlag.load(ordering: .acquiring) }

    /// The station whose sound is playing (its audio output is active), or
    /// nil.
    public func setAudioStation(_ id: UUID?) {
        audioStation.withLock { $0 = id }
    }

    public var status: Status {
        latestStatus.withLock { $0 }
    }

    // MARK: The network's thread

    /// The stations, in the order they run: by ID, so runs repeat.
    private var stations: [(id: UUID, host: EmulatorHost)] = []
    private var networkCycles: UInt64 = 0
    /// The machine each station has on the line (a power cycle makes a new
    /// one).
    private var attached: [UUID: BBCMicro] = [:]

    private func runCommands() {
        for command in commands.withLock({ list -> [Command] in
            defer { list.removeAll() }
            return list
        }) {
            switch command {
            case .add(let id, let host):
                stations.removeAll { $0.id == id }
                stations.append((id, host))
                stations.sort { $0.id.uuidString < $1.id.uuidString }
                _ = host.drivingSession()
                stationsChanged = true
            case .remove(let id):
                if let station = stations.first(where: { $0.id == id }), let machine = attached[id] {
                    bus?.detach(machine)
                    attached[id] = nil
                    _ = station
                }
                stations.removeAll { $0.id == id }
                stationsChanged = true
            case .setClock(let rate):
                bus?.clockRate = rate
            case .attachDevice(let device):
                bus?.attach(device: device)
            case .detachDevice(let device):
                bus?.detach(device: device)
            }
        }
    }

    /// Runs one quantum: every station that's ready runs `quantum` cycles,
    /// in turn. Returns whether anything ran. `caller`: a station whose
    /// tool asked for time, which runs (with the network) even if it's held
    /// or the network's paused.
    @discardableResult
    func runQuantum(caller: EmulatorHost? = nil) -> Bool {
        runCommands()
        // Only when a station needs looking at (a command, being held, a
        // debugger stop, a station added or removed) is the ready list made
        // again: this runs every 16µs.
        var attention = caller != nil || stationsChanged || caller == nil && isPaused != publishedPaused
        for station in stations where station.host.needsAttention.exchange(false, ordering: .acquiringAndReleasing) {
            attention = true
        }
        if !attention && !publishedPaused && !readyBuffer.isEmpty {
            return runReady(readyBuffer)
        }
        stationsChanged = false
        var ready = readyBuffer
        readyBuffer = []
        ready.removeAll(keepingCapacity: true)
        defer { readyBuffer = ready }
        var stopped: Set<UUID> = []
        for station in stations {
            if station.host !== caller {
                station.host.runCommands()
            }
            if station.host === caller || station.host.readyToRun() {
                ready.append(station.host)
            } else if station.host.debugStop != nil {
                stopped.insert(station.id)
                // Look again next time: it's to be noticed when it resumes.
                station.host.needsAttention.store(true, ordering: .releasing)
            }
        }
        if caller != nil {
            // Called from inside a station's commands: look again after.
            stationsChanged = true
        }
        let paused = (caller == nil && isPaused) || (!stopped.isEmpty && pausesOnBreakpoint)
        if paused != publishedPaused || stopped != publishedStopped {
            publishedPaused = paused
            publishedStopped = stopped
            latestStatus.withLock {
                $0.paused = paused
                $0.stoppedStations = stopped
            }
        }
        guard !paused else { return false }
        // Machines change only by commands (a power cycle, a save state):
        // the line's told here, not every quantum.
        if let bus {
            var machinesChanged = false
            for station in stations {
                let machine = station.host.drivingSession().machine
                if station.host.lineMachine !== machine {
                    if let old = station.host.lineMachine { bus.detach(old) }
                    bus.attach(machine)
                    station.host.lineMachine = machine
                    attached[station.id] = machine
                    machinesChanged = true
                }
            }
            if machinesChanged || lineHosts.count != ready.count || !zip(lineHosts, ready).allSatisfy({ $0 === $1 }) {
                lineHosts = ready
                let running = Set(ready.compactMap { $0.drivingSession().machine.econet }.map(ObjectIdentifier.init))
                bus.setRunning { running.contains(ObjectIdentifier($0)) }
            }
        }
        return runReady(ready)
    }

    /// Runs a quantum of the stations that are ready.
    private func runReady(_ ready: [EmulatorHost]) -> Bool {
        if let bus {
            bus.beginQuantum()
        }
        if workers.count == 0 {
            for host in ready {
                host.timedStep(cycles: quantum)
            }
        } else {
            if rebalance || groupedHosts.count != ready.count || !zip(groupedHosts, ready).allSatisfy({ $0 === $1 }) {
                groups = LockstepWorkers.balance(ready, into: workers.count + 1)
                groupedHosts = ready
                rebalance = false
            }
            workers.run(groups, cycles: quantum)
        }
        bus?.endQuantum(cycles: quantum)
        networkCycles += UInt64(quantum)
        return true
    }

    // MARK: Threads

    /// The extra threads, when one isn't enough.
    private let workers = LockstepWorkers()
    private var groups: [[EmulatorHost]] = []
    private var readyBuffer: [EmulatorHost] = []
    /// Stations were added or removed (or a tool ran the network from
    /// inside one's commands): look at them all again.
    private var stationsChanged = true
    private var publishedPaused = false
    private var publishedStopped: Set<UUID> = []
    /// Which machines are on the line this quantum, while that's unchanged.
    private var lineHosts: [EmulatorHost] = []

    private var groupedHosts: [EmulatorHost] = []
    private var rebalance = false
    private var growBlockedUntil = ContinuousClock.now

    /// The most threads to use: the performance cores, less one for the
    /// rest of the Mac.
    static let maxThreads: Int = {
        var cores: Int32 = 0
        #if canImport(Darwin)
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
        }
        #else
        cores = Int32(linuxPerformanceCores() ?? ProcessInfo.processInfo.activeProcessorCount)
        #endif
        return max(1, Int(cores) - 1)
    }()

    #if !canImport(Darwin)
    /// Linux's count of what the Mac calls performance cores: physical
    /// cores (a core's hyperthreads count once), and on a hybrid Intel
    /// chip only its performance ones (sysfs's cpu_core).
    static func linuxPerformanceCores() -> Int? {
        func read(_ path: String) -> String? {
            (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// "0-3,8,10-11" -> [0, 1, 2, 3, 8, 10, 11].
        func cpus(_ list: String) -> Set<Int> {
            var result = Set<Int>()
            for part in list.split(separator: ",") {
                let bounds = part.split(separator: "-").compactMap { Int($0) }
                if bounds.count == 2, bounds[0] <= bounds[1] {
                    result.formUnion(bounds[0]...bounds[1])
                } else if bounds.count == 1 {
                    result.insert(bounds[0])
                }
            }
            return result
        }
        let system = "/sys/devices/system/cpu"
        guard let online = read(system + "/online").map(cpus), !online.isEmpty else { return nil }
        let performance = read("/sys/devices/cpu_core/cpus").map(cpus)
        var cores = Set<String>()
        for cpu in online where performance?.contains(cpu) ?? true {
            let topology = "\(system)/cpu\(cpu)/topology/"
            guard let core = read(topology + "core_id") else { continue }
            cores.insert("\(read(topology + "physical_package_id") ?? "0").\(read(topology + "die_id") ?? "0").\(core)")
        }
        return cores.isEmpty ? nil : cores.count
    }
    #endif

    /// Once a second: more threads if the network's falling short and never
    /// rests, fewer if it rests a lot.
    /// Runs on `count` threads from now on (for tests; on the network's
    /// thread, or before it starts).
    func useThreads(_ count: Int) {
        workers.resize(to: max(0, count - 1))
        groupedHosts = []
    }

    /// Runs the commands then `count` quanta (for tests, with the network
    /// not started).
    func runQuanta(_ count: Int) {
        runCommands()
        for _ in 0..<count { runQuantum() }
    }

    /// MACBEEB_NETWORK_THREADS fixes the count (for measuring).
    static let fixedThreads = ProcessInfo.processInfo.environment["MACBEEB_NETWORK_THREADS"].flatMap(Int.init)

    private func adjustThreads(speed: Double, restedFraction: Double, limited: Bool) {
        if let fixed = Self.fixedThreads {
            if workers.count != fixed - 1 { workers.resize(to: max(0, fixed - 1)); groupedHosts = [] }
            rebalance = true
            return
        }
        let threads = workers.count + 1
        let machines = stations.count
        // Machine time a second: what more threads can raise, whatever
        // else changes.
        let work = speed * Double(machines)
        rebalance = true
        if let trial = trial {
            self.trial = nil
            if trial.machines == machines && work < trial.work * 1.05 {
                // The extra thread didn't help (by 5%): back to fewer, for
                // a while.
                workers.resize(to: threads - 2)
                groupedHosts = []
                growBlockedUntil = .now + .seconds(10)
                blockedAtMachines = machines
                return
            }
            // It helped, or the machines changed under it (no verdict, so
            // it stays and the network carries on deciding).
        }
        // Machines added or removed: a new network, as far as threads go.
        if machines != blockedAtMachines { growBlockedUntil = .now }
        let falling = (limited ? speed < 0.98 : true) && restedFraction < 0.02
        if falling && threads < Self.maxThreads && machines > threads && ContinuousClock.now >= growBlockedUntil {
            trial = (work, machines)
            workers.resize(to: threads)
            groupedHosts = []
        } else if threads > 1 && limited && (1 - restedFraction) * Double(threads) / Double(threads - 1) < 0.7 {
            workers.resize(to: threads - 2)
            groupedHosts = []
        }
    }

    /// A thread on trial: the machine time a second before it, and the
    /// machines then.
    private var trial: (work: Double, machines: Int)?
    private var blockedAtMachines = 0

    private func threadMain() {
        defer { workers.stop() }
        var rested: Duration = .zero
        func rest(_ seconds: Double) {
            let start = ContinuousClock.now
            Thread.sleep(forTimeInterval: seconds)
            rested += ContinuousClock.now - start
        }
        let clock = ContinuousClock()
        var wallStart = clock.now
        var wallStartCycles = networkCycles
        // For the speed reading.
        var sampleStart = clock.now
        var sampleCycles = networkCycles
        let audioTarget = sampleRate * 40 / 1000

        func resetWallClock() {
            wallStart = clock.now
            wallStartCycles = networkCycles
        }

        var trafficPublished = clock.now
        while running.load(ordering: .acquiring) {
            let now = clock.now
            if now - trafficPublished >= .milliseconds(100) {
                trafficPublished = now
                let traffic = traffic
                latestStatus.withLock { $0.traffic = traffic }
            }
            if now - sampleStart >= .seconds(1) {
                let elapsed = now - sampleStart
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let speed = Double(networkCycles - sampleCycles) / 2e6 / seconds
                let restedSeconds = Double(rested.components.seconds) + Double(rested.components.attoseconds) / 1e18
                if networkCycles > sampleCycles {
                    adjustThreads(speed: speed, restedFraction: restedSeconds / seconds,
                                  limited: speedLimitedFlag.load(ordering: .acquiring))
                }
                rested = .zero
                let threads = workers.count + 1
                latestStatus.withLock {
                    $0.speed = speed
                    $0.cycles = networkCycles
                    $0.threads = threads
                }
                sampleStart = now
                sampleCycles = networkCycles
            }

            // Pace: by the heard station's sound while it plays, else by the
            // wall clock.
            if speedLimitedFlag.load(ordering: .acquiring) {
                let heard = audioStation.withLock { $0 }.flatMap { id in stations.first { $0.id == id }?.host }
                if let heard, heard.isAudioActive, !heard.paused {
                    if heard.audioRing.count >= audioTarget {
                        runCommandsOnly()
                        rest(0.001)
                        continue
                    }
                    resetWallClock()
                } else {
                    let elapsed = clock.now - wallStart
                    let elapsedCycles = UInt64(max(0, Double(elapsed.components.seconds) * 2e6
                        + Double(elapsed.components.attoseconds) / 1e18 * 2e6))
                    if networkCycles - wallStartCycles >= elapsedCycles {
                        runCommandsOnly()
                        rest(0.001)
                        continue
                    }
                    // More than 0.1s behind (the Mac was busy): carry on
                    // from now rather than rushing to catch up.
                    if elapsedCycles - (networkCycles - wallStartCycles) > 200_000 {
                        resetWallClock()
                    }
                }
            }

            if !runQuantum() {
                rest(0.005)
                resetWallClock()
            }
        }
    }

    /// A station's tool wants `cycles` of time (on the network's thread,
    /// in the middle of the station's commands): the network runs that
    /// long, as fast as it can. If it can't (another station's stopped in
    /// its debugger, holding the network), the caller runs on alone.
    func runNested(cycles: Int, caller: EmulatorHost) {
        var left = cycles
        while left > 0 {
            guard runQuantum(caller: caller) else {
                caller.drivingSession().step(cycles: left)
                return
            }
            left -= quantum
        }
    }

    /// Keeps windows and tools responsive while the network waits for the
    /// wall clock.
    private func runCommandsOnly() {
        runCommands()
        for station in stations {
            station.host.runCommands()
        }
    }
}
