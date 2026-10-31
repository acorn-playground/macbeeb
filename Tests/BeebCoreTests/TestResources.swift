import Foundation

/// The tests' Resources folder. On the Mac it's inside the bundle's
/// resources (Contents/Resources/Resources); on Linux, Foundation takes a
/// bundle's top-level Resources folder to be its resources, so it's that.
let testResources: URL = {
    let resources = Bundle.module.resourceURL!
    let nested = resources.appendingPathComponent("Resources", isDirectory: true)
    return FileManager.default.fileExists(atPath: nested.path) ? nested : resources
}()
