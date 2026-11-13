import Foundation

struct Sprite {
    let palette: [Character: Pixel]
    let frames: [[[Character]]]
    let fps: Double

    var width: Int { frames.first?.first?.count ?? 0 }
    var height: Int { frames.first?.count ?? 0 }

    init(palette: [String: String], frames: [[String]], fps: Double) {
        self.palette = Dictionary(uniqueKeysWithValues: palette.compactMap { key, hex in
            guard let character = key.first, let color = pixel(hex: hex) else { return nil }
            return (character, color)
        })
        self.frames = frames.map { rows in rows.map(Array.init) }
        self.fps = fps
    }

    func draw(
        at time: TimeInterval,
        x: Int,
        y: Int,
        scale: Int = 1,
        flipped: Bool = false,
        into buffer: inout Framebuffer
    ) {
        guard !frames.isEmpty else { return }
        let rows = frames[Int(time * fps) % frames.count]
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                guard let color = palette[cell] else { continue }
                let column = flipped ? row.count - 1 - columnIndex : columnIndex
                buffer.fill(
                    Box(x: x + column * scale, y: y + rowIndex * scale, width: scale, height: scale),
                    color
                )
            }
        }
    }
}

enum SpriteLibrary {
    private struct File: Decodable {
        struct Entry: Decodable {
            let fps: Double
            let frames: [[String]]
        }

        let palette: [String: String]
        let sprites: [String: Entry]
    }

    private static let sprites: [String: Sprite] = {
        guard
            let url = Bundle.main.url(forResource: "sprites", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            preconditionFailure("sprites.json is missing from the app bundle")
        }
        return file.sprites.mapValues {
            Sprite(palette: file.palette, frames: $0.frames, fps: $0.fps)
        }
    }()

    static func named(_ name: String) -> Sprite? {
        sprites[name]
    }
}
