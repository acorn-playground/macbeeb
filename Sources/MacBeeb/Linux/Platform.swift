import BeebNetwork
import CGtk
import Foundation

/// What the shared part of the app (Sources/MacBeeb/Shared) asks of the
/// platform it runs on: on Linux, GTK and libadwaita (see
/// Shared/PlatformRequests.swift for what each does). Panels and alerts
/// are asynchronous, as GTK's are. The Mac's has the same members
/// (Sources/MacBeeb/macOS/Platform.swift).
@MainActor
enum Platform {
    /// What the user's computer is called, as in "PC layout".
    nonisolated static let keyboardName = "PC"

    /// The app's version: as installed (share/macbeeb/version), or run
    /// from the source tree, the newest release What's New lists.
    nonisolated static var appVersion: String {
        if let url = AppResources.file(installed: "version", source: ".none"),
           let version = try? String(contentsOf: url, encoding: .utf8) {
            return version.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // "## 1.6" (the newest first).
        let notes = AppResources.file(installed: "WHATSNEW.md", source: "WHATSNEW.md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let heading = notes.split(separator: "\n").first { $0.hasPrefix("## ") }
        return heading.map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) } ?? "0"
    }

    /// Posted when the app becomes active (a window of it does, after none
    /// was).
    nonisolated static let didBecomeActive = Notification.Name("MacBeebDidBecomeActive")

    // MARK: Files

    static func chooseFiles(_ kind: FileKind, multiple: Bool, message: String?, completion: @escaping @MainActor ([URL]) -> Void) {
        FileDialogs.open(kind, multiple: multiple, title: message, completion)
    }

    static func chooseSaveLocation(_ kind: FileKind, suggestedName: String, message: String?,
                                   completion: @escaping @MainActor (URL?) -> Void) {
        FileDialogs.save(kind, suggestedName: suggestedName, title: message, completion)
    }

    static func noteRecentDocument(_ url: URL) {
        Launcher.noteRecent(url)
    }

    static func open(_ url: URL) {
        Launcher.open(url)
    }

    /// Moves a file to the Trash (the desktop's, through GIO).
    static func trash(_ url: URL) throws {
        let file = url.gFile
        defer { g_object_unref(gpointer(file)) }
        var error: UnsafeMutablePointer<GError>?
        guard g_file_trash(file, nil, &error) != 0 else {
            let message = error.map { String(cString: $0.pointee.message) } ?? "Couldn’t move it to the Trash."
            if let error { g_error_free(error) }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func reveal(_ url: URL) {
        Launcher.reveal(url)
    }

    // MARK: Alerts

    /// Over the window in front.
    private static var parent: Widget? {
        Application.shared.activeWindow.map(Widget.init)
    }

    static func showError(_ error: Error) {
        let (title, detail) = describe(error)
        AlertDialog(title, body: detail)
            .response("ok", "_OK", .suggested)
            .defaults(default: "ok", close: "ok")
            .present(over: parent)
    }

    static func showAlert(title: String, message: String) {
        AlertDialog(title, body: message)
            .response("ok", "_OK", .suggested)
            .defaults(default: "ok", close: "ok")
            .present(over: parent)
    }

    static func confirm(title: String, message: String, action: String, cancel: String = "Cancel", destructive: Bool = false,
                        completion: @escaping @MainActor (Bool) -> Void) {
        AlertDialog(title, body: message)
            .response("cancel", mnemonic(cancel))
            .response("action", mnemonic(action), destructive ? .destructive : .suggested)
            .defaults(default: destructive ? "cancel" : "action", close: "cancel")
            .choose(over: parent) { completion($0 == "action") }
    }

    /// "Remove" -> "_Remove", for a keyboard mnemonic.
    private static func mnemonic(_ label: String) -> String {
        label.contains("_") ? label : "_" + label
    }

    /// An error's title and explanation, as NSAlert(error:) gives them.
    static func describe(_ error: Error) -> (title: String, detail: String?) {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return (description, localized.recoverySuggestion ?? localized.failureReason)
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return (nsError.localizedDescription, nsError.localizedRecoverySuggestion ?? nsError.localizedFailureReason)
        }
        return ("The operation couldn’t be completed.", String(describing: error))
    }

    // MARK: The clipboard

    static func readClipboardText(_ completion: @escaping @MainActor (String) -> Void) {
        Clipboard.readText(completion)
    }

    static func copyToClipboard(png: Data) {
        Clipboard.setPNG(png)
    }

    // MARK: Secrets

    /// Where Internet Econet rooms' credentials are kept: the Secret
    /// Service (GNOME Keyring), or where there isn't one, a file only the
    /// user can read.
    nonisolated static func credentialStore() -> RoomCredentialStore {
        SecretServiceCredentialStore()
    }

    // MARK: Pictures

    /// A picture of 0x00RRGGBB pixels.
    nonisolated static func image(pixels: [UInt32], width: Int, height: Int) -> PlatformImage? {
        PlatformImage(pixels: pixels, width: width, height: height)
    }

    /// A picture from a PNG, JPEG or TIFF file's bytes.
    nonisolated static func image(encoded data: Data) -> PlatformImage? {
        PlatformImage(encoded: data)
    }

    /// A picture as JPEG, at `quality` (0-1).
    nonisolated static func jpeg(_ image: PlatformImage, quality: Double) -> Data? {
        let pixels = image.pixels()
        var rgb = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for (index, pixel) in pixels.enumerated() {
            rgb[index * 3] = UInt8(truncatingIfNeeded: pixel >> 16)
            rgb[index * 3 + 1] = UInt8(truncatingIfNeeded: pixel >> 8)
            rgb[index * 3 + 2] = UInt8(truncatingIfNeeded: pixel)
        }
        var size: gsize = 0
        guard let buffer = rgb.withUnsafeBufferPointer({
            macbeeb_jpeg($0.baseAddress, Int32(image.width), Int32(image.height), Int32(quality * 100), &size)
        }) else { return nil }
        defer { g_free(buffer) }
        return Data(bytes: buffer, count: Int(size))
    }
}

/// A picture: a GDK texture, which (being immutable) any thread may make
/// and share. The Mac's is a CGImage.
final class PlatformImage: @unchecked Sendable {
    /// The GdkTexture.
    let texture: OpaquePointer
    let width: Int
    let height: Int

    /// Takes ownership of `texture`.
    init(texture: OpaquePointer) {
        self.texture = texture
        width = Int(gdk_texture_get_width(texture))
        height = Int(gdk_texture_get_height(texture))
    }

    /// From 0x00RRGGBB pixels (B, G, R, x in memory).
    convenience init?(pixels: [UInt32], width: Int, height: Int) {
        guard width > 0, height > 0, pixels.count >= width * height else { return nil }
        let bytes = pixels.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize(width * height * 4)) }
        defer { g_bytes_unref(bytes) }
        guard let texture = gdk_memory_texture_new(Int32(width), Int32(height), GDK_MEMORY_B8G8R8X8, bytes, gsize(width * 4)) else {
            return nil
        }
        self.init(texture: texture)
    }

    convenience init?(encoded data: Data) {
        let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        var error: UnsafeMutablePointer<GError>?
        guard let texture = gdk_texture_new_from_bytes(bytes, &error) else {
            if let error { g_error_free(error) }
            return nil
        }
        self.init(texture: texture)
    }

    deinit {
        g_object_unref(gpointer(texture))
        if let surface = _surface { cairo_surface_destroy(surface) }
    }

    /// Its pixels, 0xAARRGGBB (premultiplied: Cairo's ARGB32).
    func pixels() -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            gdk_texture_download(texture, buffer.baseAddress?.assumingMemoryBound(to: guchar.self), gsize(width * 4))
        }
        return pixels
    }

    private var _surface: OpaquePointer?

    /// A Cairo surface of it, for drawing (made when first wanted, on the
    /// main thread).
    @MainActor
    var cairoSurface: OpaquePointer? {
        if let _surface { return _surface }
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height)) else { return nil }
        cairo_surface_flush(surface)
        gdk_texture_download(texture, cairo_image_surface_get_data(surface), gsize(cairo_image_surface_get_stride(surface)))
        cairo_surface_mark_dirty(surface)
        _surface = surface
        return surface
    }
}

/// Internet Econet rooms' credentials in the Secret Service (GNOME
/// Keyring), as the Mac keeps them in the Keychain: one secret per service
/// origin and room. Where there's no Secret Service, a file only the user
/// can read.
struct SecretServiceCredentialStore: RoomCredentialStore {
    private let fallback = FileCredentialStore()

    private func account(_ service: URL, _ roomId: String) -> String {
        "\(InternetEconetService.origin(service)) \(roomId)"
    }

    func credentials(service: URL, roomId: String) -> RoomCredentials? {
        var failed: gboolean = 0
        if let secret = macbeeb_secret_lookup(account(service, roomId), &failed) {
            defer { g_free(secret) }
            return try? JSONDecoder().decode(RoomCredentials.self, from: Data(String(cString: secret).utf8))
        }
        return fallback.credentials(service: service, roomId: roomId)
    }

    func save(_ credentials: RoomCredentials, service: URL, roomId: String) throws {
        let json = String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self)
        let label = "MacBeeb Econet room (\(InternetEconetService.origin(service)))"
        if macbeeb_secret_store(account(service, roomId), label, json) != 0 {
            return
        }
        try fallback.save(credentials, service: service, roomId: roomId)
    }

    func remove(service: URL, roomId: String) {
        macbeeb_secret_clear(account(service, roomId))
        fallback.remove(service: service, roomId: roomId)
    }
}

/// How the disc contents are sorted (the Mac's are its table's
/// NSSortDescriptors): a column's key, and which way.
struct DiscSort: Equatable {
    var key: String?
    var ascending: Bool

    init(key: String, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }
}
