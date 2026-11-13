import Foundation

/// What the board shows with every integration off and no cards: the character kills time.
struct EmptyBoard {
    private struct Act {
        var sprite: String
        var seconds: TimeInterval
        var caption: String
        /// Where the character stands: 0 is the left end of the stage, 1 the right one.
        var from = Self.home
        var to = Self.home
        var isFlipped = false
        /// Peak height of a jump, in board cells.
        var hop = 0
        var isLeverOn = false
        var tumbleweed: (from: Double, to: Double)?

        static let home = 0.3
        static let lever = 0.58
    }

    private static let weedAhead = 0.42
    private static let weedBehind = 0.18
    private static let weedStart = 1.2
    private static let weedEnd = -0.2

    private static let acts: [Act] = [
        Act(sprite: "idle", seconds: 4, caption: "nothing is on"),
        Act(sprite: "look", seconds: 5, caption: "anyone here?"),
        Act(sprite: "bored", seconds: 4, caption: "so quiet"),
        Act(sprite: "walk", seconds: 1.8, caption: "", to: Act.lever),
        Act(sprite: "press", seconds: 0.7, caption: "click", from: Act.lever, to: Act.lever),
        Act(sprite: "hopeful", seconds: 1.6, caption: "is it on?", from: Act.lever, to: Act.lever, isLeverOn: true),
        Act(sprite: "shrug", seconds: 3.5, caption: "still off", from: Act.lever, to: Act.lever),
        Act(sprite: "walk", seconds: 1.8, caption: "", from: Act.lever, isFlipped: true),
        Act(sprite: "watch", seconds: 2.4, caption: "...", tumbleweed: (weedStart, weedAhead)),
        Act(sprite: "leap", seconds: 0.8, caption: "!", hop: 30, tumbleweed: (weedAhead, weedBehind)),
        Act(sprite: "watch", seconds: 1.2, caption: "...", isFlipped: true, tumbleweed: (weedBehind, weedEnd)),
        Act(sprite: "listen", seconds: 6, caption: "no signal"),
        Act(sprite: "sleep", seconds: 8, caption: "zzz"),
        Act(sprite: "alert", seconds: 0.8, caption: "!"),
    ]
    private static let cycle = acts.reduce(0) { $0 + $1.seconds }

    private static let scale = 3
    private static let spriteSide = 16 * scale
    private static let margin = 3
    private static let captionGap = 6
    private static let hint = "swipe right for catalog"

    private let font = PixelFont.shared

    func draw(time: TimeInterval, top: Int, into buffer: inout Framebuffer) {
        var elapsed = time.truncatingRemainder(dividingBy: Self.cycle)
        for act in Self.acts {
            if elapsed < act.seconds {
                perform(act, elapsed: elapsed, top: top, into: &buffer)
                return
            }
            elapsed -= act.seconds
        }
    }

    private func perform(_ act: Act, elapsed: TimeInterval, top: Int, into buffer: inout Framebuffer) {
        let ground = top + (buffer.height - top + Self.spriteSide) / 2
        let progress = elapsed / act.seconds

        buffer.fill(Box(x: Self.margin, y: ground, width: buffer.width - 2 * Self.margin, height: 1), Palette.line)
        let lever = act.isLeverOn ? "lever_on" : "lever_off"
        place(lever, position: 1, ground: ground, elapsed: elapsed, into: &buffer)
        place(
            act.sprite, position: act.from + (act.to - act.from) * progress,
            ground: ground - Int(Double(act.hop) * sin(progress * .pi)),
            elapsed: elapsed, isFlipped: act.isFlipped, into: &buffer
        )
        if let weed = act.tumbleweed {
            place(
                "tumbleweed", position: weed.from + (weed.to - weed.from) * progress,
                ground: ground, elapsed: elapsed, into: &buffer
            )
        }

        var y = ground + Self.captionGap
        drawCentered(act.caption, y: y, color: Palette.text, into: &buffer)
        y += 2 * Scene.lineHeight
        for line in font.wrap(Self.hint, width: buffer.width - 2 * Self.margin) {
            drawCentered(line, y: y, color: Palette.dim, into: &buffer)
            y += Scene.lineHeight
        }
    }

    private func place(
        _ name: String,
        position: Double,
        ground: Int,
        elapsed: TimeInterval,
        isFlipped: Bool = false,
        into buffer: inout Framebuffer
    ) {
        let stageWidth = buffer.width - 2 * Self.margin - Self.spriteSide
        SpriteLibrary.named(name)?.draw(
            at: elapsed,
            x: Self.margin + Int(Double(stageWidth) * position),
            y: ground - Self.spriteSide,
            scale: Self.scale,
            flipped: isFlipped,
            into: &buffer
        )
    }

    private func drawCentered(_ text: String, y: Int, color: Pixel, into buffer: inout Framebuffer) {
        font.draw(text, x: (buffer.width - font.width(of: text)) / 2, y: y, color: color, into: &buffer)
    }
}
