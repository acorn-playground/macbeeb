// File path manipulation: NSString's on the Mac, and the same rules (for
// the paths BeebCore handles) where there's only FoundationEssentials.

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

extension String {
    /// "/a/b.ssd" -> "b.ssd".
    var pathLastComponent: String {
        #if os(WASI)
        let trimmed = pathTrimmingTrailingSlashes
        guard trimmed != "/" else { return "/" }
        return trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        #else
        (self as NSString).lastPathComponent
        #endif
    }

    /// "/a/b.ssd" -> "/a".
    var pathDeletingLastComponent: String {
        #if os(WASI)
        let trimmed = pathTrimmingTrailingSlashes
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
        #else
        (self as NSString).deletingLastPathComponent
        #endif
    }

    /// "b.ssd" -> "ssd"; "" without one.
    var pathFileExtension: String {
        #if os(WASI)
        let name = pathLastComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
        #else
        (self as NSString).pathExtension
        #endif
    }

    func pathAppendingComponent(_ component: String) -> String {
        #if os(WASI)
        guard !isEmpty else { return component }
        guard !component.isEmpty else { return self }
        let base = pathTrimmingTrailingSlashes
        return (base == "/" ? "/" : base + "/") + String(component.drop { $0 == "/" })
        #else
        (self as NSString).appendingPathComponent(component)
        #endif
    }

    /// With "." and ".." components resolved and repeated slashes removed.
    var pathStandardized: String {
        #if os(WASI)
        let absolute = hasPrefix("/")
        var parts: [Substring] = []
        for part in split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                if let last = parts.last, last != ".." { parts.removeLast() } else if !absolute { parts.append(part) }
            default: parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined
        #else
        (self as NSString).standardizingPath
        #endif
    }

    #if os(WASI)
    private var pathTrimmingTrailingSlashes: String {
        var s = Substring(self)
        while s.count > 1 && s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }
    #endif
}
