import AppKit
import BeebCapture
import BeebNetwork
import ImageIO
import UniformTypeIdentifiers

/// A picture, as the platform draws them: on the Mac, a CGImage.
typealias PlatformImage = CGImage

/// What the shared part of the app (Sources/MacBeeb/Shared) asks of the
/// platform it runs on: on the Mac, AppKit (see Shared/PlatformRequests.swift
/// for what each does). Panels and alerts run modally, so completions are
/// called before these return, as the code they came from always did.
/// Linux's has the same members (Sources/MacBeeb/Linux/Platform.swift).
@MainActor
enum Platform {
    /// What the user's computer is called, as in "Mac layout".
    nonisolated static let keyboardName = "Mac"

    /// The app's version (its bundle's).
    nonisolated static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Posted when the app becomes active.
    static var didBecomeActive: Notification.Name { NSApplication.didBecomeActiveNotification }

    // MARK: Files

    /// The types a kind of file is, as the panels have always had them.
    static func contentTypes(_ kind: FileKind) -> [UTType] {
        switch kind {
        case .discs, .discsOnly: MachineController.discTypes
        case .discsAndImages: MachineController.discTypes + [.image]
        case .tapes: MachineController.tapeTypes
        case .saveState: [MachineController.stateType]
        case .png: [.png]
        case .images: [.image]
        case .movie: [.mpeg4Movie, .quickTimeMovie]
        case .pdf: [.pdf]
        case .basicText: [UTType(filenameExtension: "bas", conformingTo: .plainText) ?? .plainText]
        case .any: [.data]
        }
    }

    static func chooseFiles(_ kind: FileKind, multiple: Bool, message: String?, completion: @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        if kind != .any {
            panel.allowedContentTypes = contentTypes(kind)
        }
        if kind.allowsOthers {
            panel.allowsOtherFileTypes = true
        }
        panel.allowsMultipleSelection = multiple
        if let message {
            panel.message = message
        }
        guard panel.runModal() == .OK else {
            completion([])
            return
        }
        completion(panel.urls)
    }

    static func chooseSaveLocation(_ kind: FileKind, suggestedName: String, message: String?, completion: @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = contentTypes(kind)
        panel.nameFieldStringValue = suggestedName
        if let message {
            panel.message = message
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            completion(nil)
            return
        }
        completion(url)
    }

    static func noteRecentDocument(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Moves a file to the Trash.
    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Alerts

    static func showError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    static func confirm(title: String, message: String, action: String, cancel: String = "Cancel", destructive: Bool = false,
                        completion: @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: cancel)
        if destructive {
            alert.buttons.first?.hasDestructiveAction = true
        }
        completion(alert.runModal() == .alertFirstButtonReturn)
    }

    // MARK: The clipboard

    static func readClipboardText(_ completion: @MainActor (String) -> Void) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        completion(text)
    }

    static func copyToClipboard(png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    // MARK: Secrets

    /// Where Internet Econet rooms' credentials are kept: the Keychain.
    nonisolated static func credentialStore() -> RoomCredentialStore {
        KeychainCredentialStore()
    }

    // MARK: Pictures

    /// A picture of 0x00RRGGBB pixels.
    nonisolated static func image(pixels: [UInt32], width: Int, height: Int) -> PlatformImage? {
        Screenshot.image(pixels: pixels, width: width, height: height)
    }

    /// A picture from a PNG or JPEG file's bytes.
    nonisolated static func image(encoded data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A picture as JPEG, at `quality` (0-1).
    nonisolated static func jpeg(_ image: PlatformImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// How the disc contents are sorted: on the Mac, its table's own sort
/// descriptors.
typealias DiscSort = NSSortDescriptor
