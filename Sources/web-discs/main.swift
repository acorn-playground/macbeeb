// The discs the browser version's Distributed Mandelbrot page boots (the
// Mac app's Network Studio builds them as it makes the network):
//
//   web-discs FOLDER
//
// writes, for the MODE 5 and the colour (MODE 2, VideoNuLA) versions, the
// Guide's disc (mandelbrot-guide.ssd, mandelbrot-guide-colour.ssd) and the
// Level 2 file server's (mandelbrot-server.dsd, mandelbrot-server-colour.dsd).
// scripts/build-wasm.sh runs it into .build-wasm/discs, where web/ finds
// them.

import BeebCore
import BeebNetwork
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: web-discs FOLDER\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

// A fixed date, so the discs are the same each build (the server's own
// clock is set when it starts).
let date = Level2FileServerDisc.Date(day: 1, month: 1, year: 1988)
for (coordinator, suffix) in [(MandelbrotNetwork.Coordinator.mode5, ""), (.mode2, "-colour")] {
    let guide = try MandelbrotNetwork.guideDisc(for: coordinator)
    try Data(guide).write(to: folder.appendingPathComponent("mandelbrot-guide\(suffix).ssd"))
    let server = try MandelbrotNetwork.fileServerDisc(for: coordinator, date: date)
    try Data(server.image).write(to: folder.appendingPathComponent("mandelbrot-server\(suffix).dsd"))
}
print("Mandelbrot discs in \(folder.path)")
