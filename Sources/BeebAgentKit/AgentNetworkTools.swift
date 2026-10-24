import BeebCore
import BeebHost
import Foundation

/// What the app knows of its machines beyond the default one: the Network
/// Studio's stations, by name, and its network tools. (The app implements
/// it; headless, there's none.)
public protocol MachineDirectory: Sendable {
    /// Every machine an agent can name.
    func machines() -> [AgentMachine]
    /// The machine `name` names (a station's name, its number, or its
    /// node's UUID), or why not.
    func context(for name: String) -> Result<MachineContext, AgentToolError>
    /// Runs one of the network tools (`AgentTools.networkToolNames`).
    func networkTool(_ name: String, arguments: JSONValue) -> ToolResult
}

/// A machine as list_machines describes it.
public struct AgentMachine: Sendable {
    public var id: String
    public var name: String
    public var network: String?
    public var station: Int?
    public var role: String
    public var model: String
    public var poweredOn: Bool

    public init(id: String, name: String, network: String?, station: Int?, role: String, model: String, poweredOn: Bool) {
        self.id = id
        self.name = name
        self.network = network
        self.station = station
        self.role = role
        self.model = model
        self.poweredOn = poweredOn
    }

    public var line: String {
        var text = "\(name): \(model), \(role)"
        if let network { text += ", network \"\(network)\"" }
        if let station { text += ", station \(station)" }
        text += poweredOn ? ", on" : ", off"
        return text + " (machine: \"\(id)\")"
    }
}

/// An error a tool returns, with its kind first: "not_found: ...".
public struct AgentToolError: Error, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

extension AgentTools {
    /// The machine argument every tool takes.
    static let machineProperty: JSONValue = [
        "type": "string",
        "description": "Which machine: a Network Studio station's name, station number or id (list_machines shows them). Leave it out for the standalone machine the MCP connection is attached to.",
    ]

    static let networkToolNames: Set<String> = [
        "list_machines", "network_status", "network_power", "network_pause", "network_trace", "print_jobs", "print_job",
        "export_print_job_pdf", "network_create", "network_open",
    ]

    static let networkToolDefinitions: [ToolDefinition] = [
        ToolDefinition(name: "list_machines",
                       description: "Every machine: the standalone one, and each Network Studio station (name, model, role, station number, on or off), with the id to pass as `machine` to the other tools.",
                       inputSchema: schema()),
        ToolDefinition(name: "network_status",
                       description: "The open networks: their machines (station numbers, roles, on/off/suspended), clock, problems, speed, whether paused, traffic each station has sent (frames, bytes, collisions), and what each server's console says.",
                       inputSchema: schema(["network": ["type": "string", "description": "Which network, by name (default: every open one)"] as JSONValue])),
        ToolDefinition(name: "network_power",
                       description: "Switches a network station on or off, cold-boots it, presses Break, or suspends or resumes it (a suspended station stops while the rest run on, so others waiting on it time out). Give `machine`.",
                       inputSchema: schema(["machine": machineProperty,
                                            "action": ["type": "string", "enum": ["on", "off", "cold_boot", "break", "suspend", "resume", "start_server"],
                                                       "description": "start_server starts a file or printer server's software"] as JSONValue],
                                           required: ["machine", "action"])),
        ToolDefinition(name: "network_pause",
                       description: "Pauses or resumes a whole network: no emulated time passes on any of its machines, so nothing times out.",
                       inputSchema: schema(["network": ["type": "string"] as JSONValue, "paused": ["type": "boolean"] as JSONValue],
                                           required: ["paused"])),
        ToolDefinition(name: "network_trace",
                       description: "Frames on a network's Econet, newest last, as the four-way handshake reads them: time (s), from, to, kind (scout/acknowledgement/data/broadcast), control byte, port (and its use), transaction number, status (valid, collided, aborted) and bytes (hex). `after` gives only frames after that frame number, for polling.",
                       inputSchema: schema(["network": ["type": "string"] as JSONValue,
                                            "after": ["type": "integer", "description": "Only frames after this one"] as JSONValue,
                                            "limit": ["type": "integer", "description": "Most frames to return (default 100, at most 1000)"] as JSONValue,
                                            "station": ["type": "integer", "description": "Only frames to or from this station"] as JSONValue,
                                            "problems_only": ["type": "boolean", "description": "Only collided or aborted frames"] as JSONValue])),
        ToolDefinition(name: "print_jobs",
                       description: "What's been printed (by a standalone machine's printer port or a network's printer server): each job's id, printer, time, status, bytes and pages.",
                       inputSchema: schema()),
        ToolDefinition(name: "print_job",
                       description: "One print job: its text, page by page, as it's laid out on paper, and its raw bytes (hex, the first 4K).",
                       inputSchema: schema(["id": ["type": "string"] as JSONValue], required: ["id"])),
        ToolDefinition(name: "export_print_job_pdf",
                       description: "Saves a print job as a PDF (as the Print Centre would) and returns its path.",
                       inputSchema: schema(["id": ["type": "string"] as JSONValue,
                                            "path": ["type": "string", "description": "Where to save it (default: a temporary file)"] as JSONValue],
                                           required: ["id"])),
        ToolDefinition(name: "network_create",
                       description: "Makes a new network from a template (econet_demo: a classroom with a welcome screen and demo programs on its file server; econet_times: a newsroom, reporters on three BBCs filing stories with the file server and the Editor (station 1) printing the paper on the printer server with P; distributed_mandelbrot: eight workers waiting to draw the Mandelbrot set between them, started with *CLUSTER then *MANDEL on the Guide; mandelbrot_in_colour: the same in MODE 2 with VideoNuLA colours, *MANDEL2; two_bbcs, school_classroom, bbc_and_master, empty), saves it in Documents/MacBeeb Networks and opens it, its machines switched on. Returns its machines.",
                       inputSchema: schema(["template": ["type": "string", "enum": ["econet_demo", "econet_times", "distributed_mandelbrot", "mandelbrot_in_colour", "two_bbcs", "school_classroom", "bbc_and_master", "empty"]] as JSONValue,
                                            "name": ["type": "string"] as JSONValue], required: ["template"])),
        ToolDefinition(name: "network_open",
                       description: "Opens a saved network (a .macbeebnet package) and switches on its machines.",
                       inputSchema: schema(["path": ["type": "string"] as JSONValue], required: ["path"])),
    ]

    static let econetTools: [Tool] = [
        Tool(definition: ToolDefinition(
            name: "econet_status",
            description: "The machine's Econet module: station number, whether its ADLC's interrupt reaches NMI (INTON/INTOFF), and the MC6854's registers (CR1-CR4, SR1, SR2 with each bit named), FIFOs, transmitter and receiver state, /CTS and /DCD (no clock), and NMIs raised.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                guard let econet = session.machine.econet else {
                    return "No Econet module: this machine isn't on a network (Network Studio fits one to every station)."
                }
                return econet.statusReport()
            })
        },
    ]
}
