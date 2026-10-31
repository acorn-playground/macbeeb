import Foundation

/// What the shared code asks of a machine's window, posted with the
/// machine's host as the object: each platform's emulator view listens.
enum MachineWindowEvent {
    /// Resize the window so the picture's at a zoom (userInfo "zoom", a
    /// Double).
    static let setZoom = Notification.Name("MacBeebSetZoom")
    /// Capture the mouse for the AMX mouse, or release it.
    static let toggleMouseCapture = Notification.Name("MacBeebToggleMouseCapture")
    /// Bring the window showing the host to the front.
    static let bringToFront = Notification.Name("MacBeebBringToFront")
    /// Forget the keys held on the computer: the machine's been replaced
    /// (a quick load), so they've been released on the BBC.
    static let resetKeys = Notification.Name("MacBeebResetKeys")
}
