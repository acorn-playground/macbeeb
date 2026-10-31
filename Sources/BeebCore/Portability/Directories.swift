// The Mac's URL.applicationSupportDirectory, which Foundation on Linux
// hasn't got, so code that keeps MacBeeb's files reads the same on both.
// On Linux it's the XDG data directory (~/.local/share, or $XDG_DATA_HOME),
// so MacBeeb's files are in ~/.local/share/MacBeeb.

#if os(Linux)
import Foundation

extension URL {
    public static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
    }
}
#endif
