import BeebCore

/// What a debugger front end shows of a BASIC program, gathered with the
/// rest of a `DebugSnapshot`.
public struct BasicDebugSnapshot: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public var number: Int
        public var text: String
        /// The BASIC breakpoints on it.
        public var breakpoints: [BasicBreakpoint]
        public var id: Int { number }
    }

    public struct Element: Sendable, Equatable, Identifiable {
        public var indices: [Int]
        public var value: BasicValue
        public var id: [Int] { indices }
    }

    public struct Watch: Sendable, Equatable, Identifiable {
        public var expression: String
        /// The value, or why there isn't one.
        public var result: Result<BasicValue, WatchError>
        public var id: String { expression }
    }

    public struct WatchError: Error, Sendable, Equatable {
        public var message: String
    }

    /// The BASIC ROMs found, e.g. "BASIC 2".
    public var interpreters: [String]
    /// Whose BASIC this is.
    public var cpu: DebugCPU
    public var lines: [Line]
    /// Where it stopped in BASIC, if it did.
    public var stop: BasicLocation?
    public var error: BasicError?
    /// Innermost first; empty unless stopped in BASIC.
    public var frames: [BasicFrame]
    public var variables: [BasicVariable]
    /// The elements of the arrays asked for (`DebugView.basicExpanded`),
    /// by name.
    public var elements: [String: [Element]]
    public var watches: [Watch]
    public var breakpoints: [BasicBreakpoint]
    public var errorStop: BasicDebugger.ErrorStop
    /// A step (or a pause, waiting for a statement) is under way.
    public var isStepping: Bool

    /// The most array elements gathered for each array.
    public static let elementLimit = 256

    public init(machine m: BBCMicro, view: DebugView) {
        let basic = m.debugger.basic
        let cpu = basic.currentCPU
        self.cpu = cpu
        interpreters = basic.findInterpreters().filter { $0.cpu == cpu }.map(\.name)
        breakpoints = basic.breakpoints
        let byLine = Dictionary(grouping: basic.breakpoints, by: \.line)
        lines = basic.listing(cpu: cpu).map { Line(number: $0.number, text: $0.text, breakpoints: byLine[$0.number] ?? []) }
        stop = basic.stop?.location
        error = basic.error
        frames = basic.callStack()
        variables = basic.variables(cpu: cpu)
        var elements: [String: [Element]] = [:]
        for variable in variables where variable.dimensions != nil && view.basicExpanded.contains(variable.name) {
            elements[variable.name] = basic.elements(of: variable, count: Self.elementLimit, cpu: cpu)
                .map { Element(indices: $0.0, value: $0.1) }
        }
        self.elements = elements
        watches = view.basicWatches.map { expression in
            do {
                return Watch(expression: expression, result: .success(try basic.evaluate(expression, cpu: cpu)))
            } catch {
                return Watch(expression: expression, result: .failure(WatchError(message: "\(error)")))
            }
        }
        errorStop = basic.errorStop
        isStepping = basic.isStepping
    }
}
