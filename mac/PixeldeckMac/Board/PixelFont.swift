import Foundation

struct PixelFont {
    static let shared = PixelFont(resource: "font6x10")
    private static let fallback: Character = "?"

    let glyphWidth: Int
    let glyphHeight: Int
    private let glyphs: [Character: [UInt8]]

    private struct Table: Decodable {
        let width: Int
        let height: Int
        let glyphs: [String: [UInt8]]
    }

    private init(resource: String) {
        guard
            let url = Bundle.main.url(forResource: resource, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let table = try? JSONDecoder().decode(Table.self, from: data)
        else {
            preconditionFailure("the font \(resource) is missing from the app bundle")
        }
        glyphWidth = table.width
        glyphHeight = table.height
        glyphs = Dictionary(uniqueKeysWithValues: table.glyphs.compactMap { key, rows in
            key.first.map { ($0, rows) }
        })
    }

    func width(of text: String) -> Int {
        text.count * glyphWidth
    }

    /// Cuts the text to fit `width` pixels, marking the cut with an ellipsis.
    func fit(_ text: String, width: Int) -> String {
        let columns = max(1, width / glyphWidth)
        return text.count <= columns ? text : text.prefix(columns - 1) + "…"
    }

    func draw(_ text: String, x: Int, y: Int, color: Pixel, into buffer: inout Framebuffer) {
        for (index, character) in text.enumerated() {
            guard let rows = glyphs[character] ?? glyphs[Self.fallback] else { continue }
            let glyphX = x + index * glyphWidth
            for (rowIndex, row) in rows.enumerated() {
                for column in 0..<glyphWidth where row >> (glyphWidth - 1 - column) & 1 == 1 {
                    buffer.plot(x: glyphX + column, y: y + rowIndex, color)
                }
            }
        }
    }

    /// Breaks on spaces and newlines; a word wider than the line is cut into pieces.
    func wrap(_ text: String, width: Int) -> [String] {
        let columns = max(1, width / glyphWidth)
        return text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { paragraph in
            wrapParagraph(String(paragraph), columns: columns)
        }
    }

    /// Keeps at most `limit` lines; an ellipsis on the last one shows that text was cut.
    func wrap(_ text: String, width: Int, limit: Int) -> [String] {
        var lines = wrap(text, width: width)
        guard lines.count > limit else { return lines }
        lines = Array(lines.prefix(limit))
        lines[limit - 1] = String(lines[limit - 1].prefix(max(1, width / glyphWidth) - 1)) + "…"
        return lines
    }

    private func wrapParagraph(_ paragraph: String, columns: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in paragraph.split(separator: " ").flatMap({ chunks(of: String($0), size: columns) }) {
            if line.isEmpty {
                line = word
            } else if line.count + 1 + word.count <= columns {
                line += " " + word
            } else {
                lines.append(line)
                line = word
            }
        }
        lines.append(line)
        return lines
    }

    private func chunks(of word: String, size: Int) -> [String] {
        stride(from: 0, to: word.count, by: size).map { start in
            let begin = word.index(word.startIndex, offsetBy: start)
            let end = word.index(begin, offsetBy: size, limitedBy: word.endIndex) ?? word.endIndex
            return String(word[begin..<end])
        }
    }
}
