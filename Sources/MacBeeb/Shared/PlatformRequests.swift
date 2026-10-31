import BeebCore
import Foundation

// What the shared part of the app asks of the platform: files chosen,
// alerts, the clipboard, recent documents, pictures. Each platform's
// `Platform` (macOS/Platform.swift, Linux/Platform.swift) has these:
//
//     static let keyboardName: String
//     static var appVersion: String
//     static let didBecomeActive: Notification.Name
//     static func chooseFiles(_ kind: FileKind, multiple: Bool, message: String?,
//                             completion: @escaping ([URL]) -> Void)
//     static func chooseSaveLocation(_ kind: FileKind, suggestedName: String, message: String?,
//                                    completion: @escaping (URL?) -> Void)
//     static func showError(_ error: Error)
//     static func showAlert(title: String, message: String)
//     static func confirm(title: String, message: String, action: String, cancel: String,
//                         destructive: Bool, completion: @escaping (Bool) -> Void)
//     static func readClipboardText(_ completion: @escaping (String) -> Void)
//     static func copyToClipboard(png: Data)
//     static func noteRecentDocument(_ url: URL)
//     static func open(_ url: URL)
//     static func trash(_ url: URL) throws
//     static func reveal(_ url: URL)
//     static func image(pixels: [UInt32], width: Int, height: Int) -> PlatformImage?
//     static func image(encoded: Data) -> PlatformImage?
//     static func jpeg(_ image: PlatformImage, quality: Double) -> Data?
//
// The Mac's run their panels and alerts modally, so a completion is called
// before they return, as AppKit code always did; Linux's are asynchronous.
// A completion is always called: with nothing chosen (no URLs, or nil) if
// the panel was cancelled.

/// The kinds of file the shared code asks for. Each platform turns them
/// into its own (the Mac, UTTypes; Linux, file filters).
enum FileKind: Sendable, Equatable {
    /// Disc images of every format MacBeeb reads (or, the Mac's
    /// allowsOtherFileTypes, any file).
    case discs
    /// Disc images of every format MacBeeb reads, and nothing else.
    case discsOnly
    /// Disc images and pictures (for My Games).
    case discsAndImages
    /// .uef and .csw tapes (or any file).
    case tapes
    /// MacBeeb's save states (.beebstate).
    case saveState
    /// A PNG picture.
    case png
    /// Pictures of any kind.
    case images
    /// Movies: MPEG-4 (H.264) or QuickTime (ProRes).
    case movie
    /// A PDF.
    case pdf
    /// BBC BASIC as text (.bas).
    case basicText
    /// Anything.
    case any

    /// The file name extensions it covers (none: any).
    var extensions: [String] {
        switch self {
        case .discs, .discsOnly: Disc.ImageFormat.extensions
        case .discsAndImages: Disc.ImageFormat.extensions + MyGamesImages.extensions
        case .tapes: ["uef", "csw"]
        case .saveState: [SaveStateFile.fileExtension]
        case .png: ["png"]
        case .images: MyGamesImages.extensions
        case .movie: ["mp4", "mov"]
        case .pdf: ["pdf"]
        case .basicText: ["bas"]
        case .any: []
        }
    }

    /// What the file chooser calls them.
    var name: String {
        switch self {
        case .discs, .discsOnly: "Disc images"
        case .discsAndImages: "Disc images and pictures"
        case .tapes: "Tapes"
        case .saveState: "Save states"
        case .png: "PNG pictures"
        case .images: "Pictures"
        case .movie: "Movies"
        case .pdf: "PDF documents"
        case .basicText: "BBC BASIC programs"
        case .any: "All files"
        }
    }

    /// Whether files of other kinds can be chosen too.
    var allowsOthers: Bool {
        self == .discs || self == .tapes
    }
}

/// The picture formats My Games takes as covers.
enum MyGamesImages {
    static let extensions = ["jpg", "jpeg", "png", "gif", "heic", "tif", "tiff", "webp", "bmp"]
}

extension Platform {
    /// Asks for one file; nil if cancelled.
    static func chooseFile(_ kind: FileKind, message: String? = nil) async -> URL? {
        await withCheckedContinuation { continuation in
            chooseFiles(kind, multiple: false, message: message) { continuation.resume(returning: $0.first) }
        }
    }

    /// Asks for files; empty if cancelled.
    static func chooseFiles(_ kind: FileKind, message: String? = nil) async -> [URL] {
        await withCheckedContinuation { continuation in
            chooseFiles(kind, multiple: true, message: message) { continuation.resume(returning: $0) }
        }
    }

    /// Asks for confirmation of something, in an async context.
    static func confirm(title: String, message: String, action: String, cancel: String = "Cancel",
                        destructive: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            confirm(title: title, message: message, action: action, cancel: cancel, destructive: destructive) {
                continuation.resume(returning: $0)
            }
        }
    }
}
