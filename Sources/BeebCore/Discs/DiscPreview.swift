// (Quick Look's: it needs Foundation's formatters, so it isn't in the
// WebAssembly build.)
#if !os(WASI)
import Foundation

/// A disc image's catalogue as a web page, for Quick Look: its title, boot
/// option and files (each side of a double-sided DFS disc, and every ADFS
/// directory), with addresses as *INFO shows them.
public enum DiscPreview {
    public static func html(image: [UInt8], fileName: String) -> String {
        let format = Disc.ImageFormat(path: fileName)
        var body = ""
        do {
            guard let format else { throw DiscVolume.ReadError.unrecognised }
            if format == .img || format == .dos {
                body = note("A DOS disc, for the Master 512.", size: image.count)
            } else {
                let volume = try DiscVolume(disc: Disc.fromImage(image, format: format))
                body = sections(volume)
            }
        } catch let error as DiscVolume.ReadError {
            body = note(error.localizedDescription, size: image.count)
        } catch {
            body = note("This disc image can’t be read.", size: image.count)
        }
        return page(title: fileName, body: body)
    }

    static func sections(_ volume: DiscVolume) -> String {
        switch volume {
        case .dfs(let sides):
            return sides.indices.map { side in
                let location = DiscVolume.Location(side: side)
                let heading = sides.count == 2 ? "Side \(side == 0 ? "0" : "2")" : nil
                return section(heading: heading, title: volume.title(side: side),
                               boot: volume.bootOption(side: side), free: volume.freeSectors(side: side),
                               items: (try? volume.items(at: location)) ?? [], adfs: false,
                               formatted: sides[side].sectorCount > 2)
            }.joined()
        case .adfs:
            var html = section(heading: nil, title: volume.title(), boot: volume.bootOption(),
                               free: volume.freeSectors(), items: items(volume, ADFSDisc.rootSector), adfs: true)
            // Then each directory, depth first, as $.Games.Arcade.
            func directories(_ sector: Int, _ path: String, depth: Int) {
                guard depth < 16 else { return }
                for item in items(volume, sector) where item.isDirectory {
                    let name = path + "." + item.name
                    html += section(heading: name, title: nil, boot: nil, free: nil,
                                    items: items(volume, item.startSector), adfs: true)
                    directories(item.startSector, name, depth: depth + 1)
                }
            }
            directories(ADFSDisc.rootSector, "$", depth: 0)
            return html
        }
    }

    static func items(_ volume: DiscVolume, _ directory: Int) -> [DiscVolume.Item] {
        ((try? volume.items(at: DiscVolume.Location(directory: directory))) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func section(heading: String?, title: String?, boot: Int?, free: Int?, items: [DiscVolume.Item],
                        adfs: Bool, formatted: Bool = true) -> String {
        var html = "<section>"
        if let heading {
            html += "<h2>\(escape(heading))</h2>"
        }
        if let title {
            html += "<h1>\(title.isEmpty ? "<span class=dim>No title</span>" : escape(title))</h1>"
        }
        guard formatted else {
            return html + "<p class=dim>Not formatted.</p></section>"
        }
        var facts: [String] = []
        if let boot {
            facts.append("Boot: " + ["None", "*LOAD", "*RUN", "*EXEC"][boot & 3])
        }
        facts.append(items.count == 1 ? "1 file" : "\(items.count) files")
        if let free {
            facts.append(ByteCountFormatter.string(fromByteCount: Int64(free * 256), countStyle: .binary) + " free")
        }
        html += "<p class=facts>\(facts.joined(separator: " · "))</p>"
        guard !items.isEmpty else { return html + "</section>" }
        html += "<table><tr><th>Name</th><th>Load</th><th>Exec</th><th>Length</th><th>Access</th></tr>"
        for item in items {
            html += "<tr><td>\(item.isDirectory ? "📁 " : "")\(escape(item.name))</td>"
            if item.isDirectory {
                html += "<td></td><td></td><td></td>"
            } else {
                html += "<td>\(hex(item.loadAddress, adfs))</td><td>\(hex(item.executionAddress, adfs))</td>"
                html += "<td>\(String(format: "%06X", item.length))</td>"
            }
            html += "<td>\(escape(item.access))</td></tr>"
        }
        return html + "</table></section>"
    }

    static func note(_ text: String, size: Int) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .binary)
        return "<section><p>\(escape(text))</p><p class=dim>\(bytes)</p></section>"
    }

    /// As *INFO shows them: DFS's six digits (FF for the I/O processor),
    /// ADFS's eight.
    static func hex(_ address: UInt32, _ adfs: Bool) -> String {
        if adfs {
            return String(format: "%08X", address)
        }
        return address >= 0xFFFF_0000 ? String(format: "FF%04X", address & 0xFFFF) : String(format: "%06X", address)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --dim: #6e6e73; --rule: #d2d2d7; --stripe: #f5f5f7; }
        @media (prefers-color-scheme: dark) { :root { --dim: #98989d; --rule: #3a3a3c; --stripe: #1c1c1e; } }
        body { font: 13px -apple-system, sans-serif; margin: 20px 24px; }
        h1 { font-size: 20px; margin: 0 0 2px; }
        h2 { font-size: 13px; margin: 24px 0 4px; color: var(--dim); font-weight: 600; }
        .facts, .dim { color: var(--dim); margin: 0 0 10px; }
        table { border-collapse: collapse; width: 100%; }
        th { text-align: left; font-weight: 600; color: var(--dim); border-bottom: 1px solid var(--rule); padding: 4px 8px; }
        td { padding: 3px 8px; font: 12px ui-monospace, Menlo, monospace; }
        td:first-child { font: 13px -apple-system, sans-serif; }
        tr:nth-child(even) td { background: var(--stripe); }
        </style></head><body>\(body)</body></html>
        """
    }
}
#endif
