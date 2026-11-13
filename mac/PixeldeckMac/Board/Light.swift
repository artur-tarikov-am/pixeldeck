import Foundation

enum Light: String, Decodable {
    case running, waiting, done, failed, idle, review

    /// A value from a newer hub must not break the whole stream.
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Light(rawValue: value) ?? .idle
    }

    private var color: Pixel {
        switch self {
        case .running: Palette.accent
        case .waiting: Palette.yellow
        case .done: Palette.green
        case .failed: Palette.red
        case .idle: Palette.dim
        case .review: Palette.blue
        }
    }

    private func brightness(at time: TimeInterval) -> Double {
        switch self {
        case .running: 0.65 + 0.35 * sin(time * 3)
        case .waiting: time.truncatingRemainder(dividingBy: 1) < 0.6 ? 1 : 0.3
        case .done, .failed, .review, .idle: 1
        }
    }

    func draw(at time: TimeInterval, x: Int, y: Int, into buffer: inout Framebuffer) {
        let body = dimmed(color, by: brightness(at: time))
        for (rowIndex, row) in Self.shape.enumerated() {
            for (columnIndex, cell) in row.enumerated() where cell != "." {
                buffer.plot(
                    x: x + columnIndex,
                    y: y + rowIndex,
                    cell == "h" ? Palette.text : body
                )
            }
        }
    }

    static let size = 7
    static let byUrgency: [Light] = [.waiting, .running, .failed, .review, .done, .idle]

    private static let shape: [[Character]] = [
        ".ooooo.",
        "oohoooo",
        "ohooooo",
        "ooooooo",
        "ooooooo",
        "ooooooo",
        ".ooooo.",
    ].map(Array.init)
}
