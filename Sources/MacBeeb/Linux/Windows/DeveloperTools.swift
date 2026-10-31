import Foundation

// Two of the Mac app's developer tools the shared code starts, which drive
// its SwiftUI windows: the network self-test (`-MacBeebNetworkSelfTest`,
// and its MCP variant) and the documentation captures that make the
// guides' screenshots. Linux has its own self-tests (`-MacBeebSelfTest`
// and the windows' own, see MachineSelfTest.swift); these do nothing.

@MainActor
enum NetworkSelfTest {
    static var path: String? { nil }
    static func runMCPIfRequested() -> Bool { false }
    static func runIfRequested() {}
}

@MainActor
enum DocumentationCapture {
    static func start(for machine: MachineController) {}
}
