/// Draws the board's lights into GIFs for the README with the app's own drawing code.
///
/// Usage:
///   swiftc -parse-as-library -o "$TMPDIR/make_lights" tools/make_lights.swift \
///     mac/PixeldeckMac/Board/Light.swift mac/PixeldeckMac/Board/Pixels.swift
///   "$TMPDIR/make_lights" docs/images/lights
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum MakeLights {
    /// The light with one cell of tile around it.
    static let side = Light.size + 2
    /// Twice the size the README shows, so the cells stay sharp on Retina.
    static let pixelsPerCell = 4
    static let framesPerSecond = 10.0

    /// One loop of each light's brightness in `Light`. A steady light gets a single frame.
    static let loops: [(Light, TimeInterval)] = [
        (.running, 2 * .pi / 3),
        (.waiting, 1),
        (.done, 0),
        (.failed, 0),
        (.idle, 0),
        (.review, 0),
    ]

    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (light, loop) in loops {
            write(light, loop: loop, to: folder.appendingPathComponent("\(light.rawValue).gif"))
        }
    }

    static func write(_ light: Light, loop: TimeInterval, to url: URL) {
        let count = max(1, Int((loop * framesPerSecond).rounded()))
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { fatalError("cannot create \(url.path)") }
        let forever = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(gif, forever as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: loop / Double(count)]]
        for index in 0..<count {
            CGImageDestinationAddImage(gif, frame(light, at: loop * Double(index) / Double(count)), delay as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { fatalError("cannot write \(url.path)") }
    }

    static func frame(_ light: Light, at time: TimeInterval) -> CGImage {
        var buffer = Framebuffer(width: side, height: side)
        buffer.fill(Box(x: 0, y: 0, width: side, height: side), Palette.panel)
        light.draw(at: time, x: 1, y: 1, into: &buffer)
        let pixels = side * pixelsPerCell
        guard
            let cells = buffer.makeImage(),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { fatalError("cannot draw \(light.rawValue)") }
        context.interpolationQuality = .none
        context.draw(cells, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = context.makeImage() else { fatalError("cannot draw \(light.rawValue)") }
        return image
    }
}
