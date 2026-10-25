import AppKit

/// The standard About panel, with links to the project and its author.
@MainActor
enum AboutPanel {
    static let repository = URL(string: "https://github.com/acorn-playground/macbeeb")!
    static let website = URL(string: "https://jamesdrandall.com")!

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    private static var credits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: centred,
                                                     .foregroundColor: NSColor.secondaryLabelColor]
        func link(_ text: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: centred, .link: url])
        }
        let text = NSMutableAttributedString()
        text.append(link("MacBeeb on GitHub", repository))
        text.append(NSAttributedString(string: "  ·  ", attributes: plain))
        text.append(link("jamesdrandall.com", website))
        text.append(NSAttributedString(string: "\n\nOpen source under the GNU GPL v3.", attributes: plain))
        return text
    }
}
