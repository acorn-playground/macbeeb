import BeebLibrary
import CGtk
import Foundation

// Book covers: a game's bundled box art, one of My Games' own pictures,
// a typographic stand-in until there's one, and the archive's own book.

/// A picture for drawing with Cairo, read at no more than the size it's
/// shown at (twice over, for HiDPI): only that copy is kept.
final class LibraryPicture: @unchecked Sendable {
    /// A Cairo image surface (ARGB32).
    let surface: OpaquePointer
    let width: Int
    let height: Int

    /// The bundled covers' longest side (a tile's, or the details', at 2x).
    static let coverSize = 640

    /// From a picture file's bytes (PNG, JPEG, TIFF, or what GDK's
    /// loaders read), at most `maxSize` on its longest side. Any thread.
    init?(data: Data, maxSize: Int) {
        let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        var error: UnsafeMutablePointer<GError>?
        guard let texture = gdk_texture_new_from_bytes(bytes, &error) else {
            if let error { g_error_free(error) }
            return nil
        }
        defer { g_object_unref(gpointer(texture)) }
        let fullWidth = Int(gdk_texture_get_width(texture)), fullHeight = Int(gdk_texture_get_height(texture))
        guard fullWidth > 0, fullHeight > 0,
              let full = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(fullWidth), Int32(fullHeight)) else { return nil }
        cairo_surface_flush(full)
        gdk_texture_download(texture, cairo_image_surface_get_data(full), gsize(cairo_image_surface_get_stride(full)))
        cairo_surface_mark_dirty(full)
        let scale = min(1, Double(maxSize) / Double(max(fullWidth, fullHeight)))
        guard scale < 1 else {
            surface = full
            width = fullWidth
            height = fullHeight
            return
        }
        width = max(1, Int((Double(fullWidth) * scale).rounded()))
        height = max(1, Int((Double(fullHeight) * scale).rounded()))
        guard let small = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height)),
              let context = cairo_create(small) else {
            cairo_surface_destroy(full)
            return nil
        }
        cairo_scale(context, Double(width) / Double(fullWidth), Double(height) / Double(fullHeight))
        cairo_set_source_surface(context, full, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(context), CAIRO_FILTER_GOOD)
        cairo_paint(context)
        cairo_destroy(context)
        cairo_surface_destroy(full)
        surface = small
    }

    convenience init?(url: URL, maxSize: Int) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data, maxSize: maxSize)
    }

    deinit {
        cairo_surface_destroy(surface)
    }

    /// Draws it into a rectangle (stretched to it).
    @MainActor
    func draw(_ cairo: Cairo, x: Double, y: Double, width: Double, height: Double) {
        cairo.save()
        cairo.rectangle(x, y, width, height)
        cairo.clip()
        cairo.translate(x, y)
        cairo.scale(width / Double(self.width), height / Double(self.height))
        cairo_set_source_surface(cairo.context, surface, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(cairo.context), CAIRO_FILTER_GOOD)
        cairo.paint()
        cairo.restore()
    }
}

/// The Classics' bundled covers, read once (in the background, as the
/// app starts, if it's asked to).
@MainActor
enum ShelfCoverCache {
    private static var pictures: [String: LibraryPicture] = [:]
    private static var missing: Set<String> = []
    private static var preloading = false

    static func picture(for game: CuratedGame) -> LibraryPicture? {
        if let picture = pictures[game.id] { return picture }
        guard !missing.contains(game.id) else { return nil }
        guard let url = BeebLibrary.coverURL(for: game),
              let picture = LibraryPicture(url: url, maxSize: LibraryPicture.coverSize) else {
            missing.insert(game.id)
            return nil
        }
        pictures[game.id] = picture
        return picture
    }

    /// Reads every cover off the main thread, ready for the shelves.
    static func preload() {
        guard !preloading else { return }
        preloading = true
        let games = Catalogue.classics.allGames.filter { pictures[$0.id] == nil }
        Task.detached(priority: .utility) {
            var read: [(String, LibraryPicture)] = []
            for game in games {
                if let url = BeebLibrary.coverURL(for: game),
                   let picture = LibraryPicture(url: url, maxSize: LibraryPicture.coverSize) {
                    read.append((game.id, picture))
                }
            }
            let finished = read
            await MainActor.run {
                for (id, picture) in finished where pictures[id] == nil {
                    pictures[id] = picture
                }
            }
        }
    }
}

/// What a cover shows.
enum ShelfCoverContent {
    /// A picture, at its own proportions.
    case image(LibraryPicture)
    /// A Classic without a picture: its title, in the BBC's yellow.
    case classic(title: String, publisher: String?)
    /// One of My Games without a picture yet.
    case personal(title: String)
    /// The archive's book.
    case archive
    /// Nothing (yet): one of My Games' pictures loading.
    case empty

    /// Width over height.
    var aspect: Double {
        switch self {
        case .image(let picture): Double(picture.width) / Double(max(picture.height, 1))
        default: 0.7
        }
    }
}

/// A cover drawn as large as fits a box, standing on the box's bottom
/// edge, rounded and with a shadow (the "shelf-cover" style).
@MainActor
final class ShelfCover {
    let area: DrawingArea
    let box: Widget
    private let boxWidth: Double
    private let boxHeight: Double
    private(set) var content: ShelfCoverContent
    /// Until its widget's gone (a picture read in the background may
    /// arrive after).
    private var alive = true

    static let radius = 4.0

    init(width: Double, height: Double, content: ShelfCoverContent = .empty) {
        boxWidth = width
        boxHeight = height
        self.content = content
        area = DrawingArea { _, _, _ in }
        area.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_END)
        area.style("shelf-cover")
        // The box keeps its size whatever the cover's proportions.
        box = Bin(area).size(width: Int32(width), height: Int32(height))
        // (The area keeps its draw function, which keeps this: wrappers
        // don't own their widgets, so there's no cycle.)
        area.setDraw { [self] cairo, width, height in draw(cairo, width, height) }
        area.object.whenFinalised { [weak self] in self?.alive = false }
        macbeeb_library_accessible_hidden(area.widget)
        set(content)
    }

    func set(_ content: ShelfCoverContent) {
        guard alive else { return }
        self.content = content
        let aspect = content.aspect
        var width = boxWidth, height = boxWidth / aspect
        if height > boxHeight {
            height = boxHeight
            width = boxHeight * aspect
        }
        area.contentSize(width: Int32(width.rounded()), height: Int32(height.rounded()))
        area.setStyle("pop", { if case .image = content { true } else { false } }())
        area.isVisible = { if case .empty = content { false } else { true } }()
        area.queueDraw()
    }

    // MARK: Drawing

    private func draw(_ cairo: Cairo, _ width: Double, _ height: Double) {
        cairo.save()
        cairo.roundedRectangle(0, 0, width, height, radius: Self.radius)
        cairo.clip()
        switch content {
        case .image(let picture):
            picture.draw(cairo, x: 0, y: 0, width: width, height: height)
        case .classic(let title, let publisher):
            Self.drawPlaceholder(cairo, width, height, title: title, caption: publisher,
                                 top: .init(0.18, 0.18, 0.18), bottom: .init(0.08, 0.08, 0.08),
                                 titleColour: .init(1, 0.84, 0.04), captionColour: .init(1, 1, 1, 0.7))
        case .personal(let title):
            Self.drawPlaceholder(cairo, width, height, title: title, caption: "Drop a cover here",
                                 top: .init(0.12, 0.16, 0.24), bottom: .init(0.05, 0.07, 0.12),
                                 titleColour: .init(0.39, 0.82, 1), captionColour: .init(1, 1, 1, 0.6))
        case .archive:
            Self.drawArchive(cairo, width, height)
        case .empty:
            break
        }
        cairo.restore()
    }

    /// A plain cover: the title in capitals, centred, and a caption.
    private static func drawPlaceholder(_ cairo: Cairo, _ width: Double, _ height: Double, title: String, caption: String?,
                                        top: LibraryText.Colour, bottom: LibraryText.Colour,
                                        titleColour: LibraryText.Colour, captionColour: LibraryText.Colour) {
        cairo.rectangle(0, 0, width, height)
        LibraryText.fillGradient(cairo, top: top, bottom: bottom, height: height)
        let inset = 10.0, textWidth = width - inset * 2
        let titleFont = "Monospace Bold \(height > 230 ? 15 : 13)"
        let captionFont = "Sans 8"
        let titleHeight = LibraryText.draw(cairo, title.uppercased(), font: titleFont, colour: titleColour, x: inset, y: 0,
                                           width: textWidth, alignment: PANGO_ALIGN_CENTER, measureOnly: true)
        let captionHeight = caption.map {
            LibraryText.draw(cairo, $0, font: captionFont, colour: captionColour, x: inset, y: 0, width: textWidth,
                             alignment: PANGO_ALIGN_CENTER, measureOnly: true)
        } ?? 0
        let gap = caption == nil ? 0 : 8.0
        var y = (height - titleHeight - gap - captionHeight) / 2
        LibraryText.draw(cairo, title.uppercased(), font: titleFont, colour: titleColour, x: inset, y: y, width: textWidth,
                         alignment: PANGO_ALIGN_CENTER)
        y += titleHeight + gap
        if let caption {
            LibraryText.draw(cairo, caption, font: captionFont, colour: captionColour, x: inset, y: y, width: textWidth,
                             alignment: PANGO_ALIGN_CENTER)
        }
    }

    /// The archive's book: typographic, in the BBC Micro's colours, with
    /// no third-party logo.
    private static func drawArchive(_ cairo: Cairo, _ width: Double, _ height: Double) {
        cairo.rectangle(0, 0, width, height)
        LibraryText.fillGradient(cairo, top: .init(0.16, 0.13, 0.11), bottom: .init(0.08, 0.07, 0.06), height: height)
        // The BBC Micro's red function keys, as a band.
        cairo.color(0.78, 0.12, 0.12)
        for band in 0..<3 {
            cairo.rectangle(0, 22 + Double(band) * 7, width, 4)
        }
        cairo.fill()
        let gold = LibraryText.Colour(0.95, 0.78, 0.3)
        let inset = 12.0, textWidth = width - inset * 2
        let lines: [(String, String, LibraryText.Colour)] = [
            ("The BBC Micro Archive", "Serif Bold 13", .init(1, 1, 1)),
            ("BBCMicro.co.uk", "Monospace 8", gold),
            ("Thousands more games", "Sans 7", .init(1, 1, 1, 0.7)),
        ]
        let spacing = 5.0
        let heights = lines.map {
            LibraryText.draw(cairo, $0.0, font: $0.1, colour: $0.2, x: inset, y: 0, width: textWidth, measureOnly: true)
        }
        let booksHeight = 30.0
        var y = height - inset - heights.reduce(0, +) - spacing * Double(lines.count) - booksHeight
        drawBooks(cairo, x: inset, y: y, height: booksHeight, colour: gold)
        y += booksHeight + spacing
        for (line, lineHeight) in zip(lines, heights) {
            LibraryText.draw(cairo, line.0, font: line.1, colour: line.2, x: inset, y: y, width: textWidth)
            y += lineHeight + spacing
        }
    }

    /// Three books standing together.
    private static func drawBooks(_ cairo: Cairo, x: Double, y: Double, height: Double, colour: LibraryText.Colour) {
        let books: [(width: Double, height: Double)] = [(7, 0.84), (9, 1), (7, 0.9)]
        var left = x
        for book in books {
            let bookHeight = height * book.height
            cairo.color(colour.red, colour.green, colour.blue)
            cairo.roundedRectangle(left, y + height - bookHeight, book.width, bookHeight, radius: 1.5)
            cairo.fill()
            // A band across the spine.
            cairo.color(0.16, 0.13, 0.11, 0.55)
            cairo.rectangle(left + 1.5, y + height - bookHeight + 4, book.width - 3, 2)
            cairo.fill()
            left += book.width + 2
        }
    }
}

extension ShelfCover {
    /// A Classic's cover.
    static func classic(_ game: CuratedGame, width: Double, height: Double) -> ShelfCover {
        let content: ShelfCoverContent = ShelfCoverCache.picture(for: game).map { .image($0) }
            ?? .classic(title: game.title, publisher: game.publisher)
        return ShelfCover(width: width, height: height, content: content)
    }

    /// One of My Games' covers: its picture (read off the main thread), or
    /// its title until it has one.
    static func personal(_ game: PersonalGame, width: Double, height: Double) -> ShelfCover {
        let cover = ShelfCover(width: width, height: height, content: .empty)
        cover.load(game)
        return cover
    }

    func load(_ game: PersonalGame) {
        guard let url = ClassicsLibrary.shared.myGames.coverURL(game) else {
            set(.personal(title: game.title))
            return
        }
        if let picture = PersonalCoverCache.picture(url) {
            set(.image(picture))
            return
        }
        Task {
            let picture = await Task.detached { LibraryPicture(url: url, maxSize: LibraryPicture.coverSize) }.value
            if let picture {
                PersonalCoverCache.store(picture, for: url)
                self.set(.image(picture))
            } else {
                self.set(.personal(title: game.title))
            }
        }
    }
}

/// My Games' covers, read once each (each new cover has a new name).
@MainActor
enum PersonalCoverCache {
    private static var pictures: [URL: LibraryPicture] = [:]

    static func picture(_ url: URL) -> LibraryPicture? { pictures[url] }

    static func store(_ picture: LibraryPicture, for url: URL) {
        if pictures.count > 64 { pictures.removeAll() }
        pictures[url] = picture
    }
}
