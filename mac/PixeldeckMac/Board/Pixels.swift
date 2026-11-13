import CoreGraphics
import Foundation

/// Colors are stored the way they are laid out in memory: 0xAABBGGRR on little-endian devices.
typealias Pixel = UInt32

func pixel(red: UInt8, green: UInt8, blue: UInt8) -> Pixel {
    0xFF00_0000 | UInt32(blue) << 16 | UInt32(green) << 8 | UInt32(red)
}

func pixel(hex: String) -> Pixel? {
    guard hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return pixel(
        red: UInt8(value >> 16 & 0xFF),
        green: UInt8(value >> 8 & 0xFF),
        blue: UInt8(value & 0xFF)
    )
}

func dimmed(_ color: Pixel, by factor: Double) -> Pixel {
    let channel = { (shift: UInt32) in UInt8(Double(color >> shift & 0xFF) * factor) }
    return pixel(red: channel(0), green: channel(8), blue: channel(16))
}

enum Palette {
    /// The notch itself is black, so the board grows out of it without a seam.
    static let black = pixel(red: 0, green: 0, blue: 0)
    static let panel = pixel(red: 0x16, green: 0x12, blue: 0x1E)
    static let line = pixel(red: 0x3A, green: 0x33, blue: 0x48)
    static let dim = pixel(red: 0x8A, green: 0x82, blue: 0x9A)
    static let text = pixel(red: 0xF5, green: 0xEF, blue: 0xE6)
    static let accent = pixel(red: 0xE0, green: 0x7A, blue: 0x4B)
    static let yellow = pixel(red: 0xF2, green: 0xC1, blue: 0x4E)
    static let green = pixel(red: 0x6B, green: 0xCB, blue: 0x77)
    static let red = pixel(red: 0xE5, green: 0x48, blue: 0x4D)
    static let blue = pixel(red: 0x6F, green: 0xB7, blue: 0xE9)
}

struct Box {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }

    func contains(x pointX: Int, y pointY: Int) -> Bool {
        pointX >= x && pointX < maxX && pointY >= y && pointY < maxY
    }

    func expanded(by amount: Int) -> Box {
        Box(x: x - amount, y: y - amount, width: width + 2 * amount, height: height + 2 * amount)
    }

    /// The cells of `row` that stay once the corners are cut round: in a corner only those
    /// whose centers fall inside a circle of `radius`. Coordinates are doubled to put the centers on whole numbers.
    func cells(inRow row: Int, radius: Int) -> Range<Int> {
        guard row >= y, row < maxY else { return x..<x }
        let radius = min(radius, width / 2, height / 2)
        let fromEdge = min(row - y, maxY - 1 - row)
        guard fromEdge < radius else { return x..<maxX }
        let dy = 2 * (radius - fromEdge) - 1
        let inset = (0..<radius).first { column in
            let dx = 2 * (radius - column) - 1
            return dx * dx + dy * dy <= 4 * radius * radius
        } ?? radius
        return x + inset..<maxX - inset
    }
}

struct Framebuffer {
    let width: Int
    let height: Int
    private var pixels: [Pixel]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = Array(repeating: Palette.black, count: width * height)
    }

    mutating func plot(x: Int, y: Int, _ color: Pixel) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = color
    }

    mutating func fill(_ box: Box, _ color: Pixel, radius: Int = 0) {
        for y in box.y..<box.maxY {
            for x in box.cells(inRow: y, radius: radius) {
                plot(x: x, y: y, color)
            }
        }
    }

    /// The cells at the ends of each row and those with nothing above or below them.
    mutating func stroke(_ box: Box, _ color: Pixel, radius: Int = 0) {
        for y in box.y..<box.maxY {
            let row = box.cells(inRow: y, radius: radius)
            let above = box.cells(inRow: y - 1, radius: radius)
            let below = box.cells(inRow: y + 1, radius: radius)
            for x in row where x == row.first || x == row.last || !above.contains(x) || !below.contains(x) {
                plot(x: x, y: y, color)
            }
        }
    }

    func makeImage() -> CGImage? {
        let bytes = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
