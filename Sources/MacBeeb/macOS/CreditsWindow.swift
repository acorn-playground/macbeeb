import AppKit
import SwiftUI

/// Help > Credits: the work MacBeeb is built on and includes, from
/// CREDITS.md. The app bundle has it in Contents/Resources (scripts/
/// make-app.sh copies it); run from the source tree, it's read from there.
struct CreditsWindow: View {
    static let windowID = "credits"

    var body: some View {
        if let text = Self.text {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MacBeeb").font(.title.weight(.semibold))
                            Text("With thanks to everyone whose work it builds on")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 8)
                    // The document's own title is the header above.
                    GuideDocumentView(blocks: GuideBlock.parse(text, base: nil).filter {
                        if case .heading(1, _) = $0 { false } else { true }
                    })
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 560, minHeight: 480)
        } else {
            ContentUnavailableView("No credits", systemImage: "heart",
                                   description: Text("The credits weren’t found in the app."))
                .frame(minWidth: 560, minHeight: 480)
        }
    }

    static var text: String? {
        if let bundled = Bundle.main.url(forResource: "Credits", withExtension: "md"),
           let text = try? String(contentsOf: bundled, encoding: .utf8) {
            return text
        }
        // Run from the source tree: Sources/MacBeeb/macOS/CreditsWindow.swift ->
        // CREDITS.md.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CREDITS.md")
        return try? String(contentsOf: source, encoding: .utf8)
    }
}

/// Help > Credits.
struct CreditsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Credits") { openWindow(id: CreditsWindow.windowID) }
    }
}
