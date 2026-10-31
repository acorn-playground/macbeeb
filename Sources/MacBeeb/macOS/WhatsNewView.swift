import AppKit
import SwiftUI

/// Help > What's New in MacBeeb, also opened on the first launch after an
/// update: the release notes, newest first, with those since the last
/// version the user ran marked New.
struct WhatsNewView: View {
    static let windowID = "whats-new"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New in MacBeeb").font(.title2.weight(.semibold))
                    Text("Version \(WhatsNew.currentVersion)").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if WhatsNew.releases.isEmpty {
                        Text("There are no release notes in this build.").foregroundStyle(.secondary)
                    }
                    ForEach(WhatsNew.releases) { release in
                        ReleaseSection(release: release)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                Link("All releases on GitHub", destination: AboutPanel.repository.appendingPathComponent("releases"))
                    .font(.callout)
                Spacer()
                Button("Continue") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 520)
    }
}

private struct ReleaseSection: View {
    let release: WhatsNew.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(release.version).font(.headline)
                if let date = release.date {
                    Text(date).font(.subheadline).foregroundStyle(.secondary)
                }
                if WhatsNew.isNew(release, since: WhatsNew.previousVersion) {
                    Text("New")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
            ForEach(release.intro, id: \.self) { line in
                Text(markdown(line))
            }
            ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(markdown(item)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Help > What's New in MacBeeb.
struct WhatsNewMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("What's New in MacBeeb") { openWindow(id: WhatsNewView.windowID) }
    }
}
