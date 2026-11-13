import Foundation

/// A row pushed aside by a swipe, with the close button in the gap.
struct SwipedRow {
    let key: String
    let offsetAtGrab: Double
    var offset: Double
    var rest: Double
}

/// A scrolling column of cards, used for the feed and for the list of pull requests.
@MainActor
final class CardFeed {
    private static let padding = 4
    private static let cardGap = 4
    private static let iconGap = 4
    private static let buttonHeight = 15
    private static let buttonGap = 3
    private static let lightTitleLines = 2
    /// The corners of the tiles on the board, on the finer grid of the feed.
    private static let cornerRadius = Int((CGFloat(Scene.cornerRadius) * Scene.boardPixel / Scene.feedPixel).rounded())
    private static let buttonCornerRadius = 2

    /// Same decay as UIScrollView's normal deceleration rate of 0.998 per millisecond.
    private static let friction = 2.0
    private static let stopSpeed = 5.0
    private static let maxSpeed = 3000.0
    /// Critically damped spring that brings an overscrolled feed back to its edge.
    private static let springStrength = 14.0
    private static let settledOverscroll = 0.25
    /// How much of a drag past the end actually moves the feed.
    private static let dragResistance = 0.5
    private static let physicsStep = 1.0 / 240
    private static let closeLabel = "close"
    private static let rowSettleRate = 20.0
    private static let settledRowDistance = 0.5
    /// How much of the row a finger has to cover for the swipe itself to close it.
    private static let closeLine = 0.6
    private static let pinInset = 3
    private static let pin: [[Character]] = [
        ".ooo.",
        ".ooo.",
        ".ooo.",
        "ooooo",
        "..o..",
        "..o..",
        "..o..",
    ].map(Array.init)

    private let font = PixelFont.shared
    var scroll = 0.0
    private var velocity = 0.0
    private var isHeld = false
    private var lastAdvance: TimeInterval?
    private var maxScroll = 0.0
    /// Cells from the top of the first card to the bottom of the last one, as last drawn.
    private(set) var contentHeight = 0
    private(set) var swipedRow: SwipedRow?
    private var rowWidth = 0

    private var closeButtonWidth: Double { Double(font.width(of: Self.closeLabel) + 4 * Self.padding) }
    private var isRowSettling: Bool { swipedRow.map { $0.offset != $0.rest } ?? false }

    /// Whole cells, because the row is drawn into the grid.
    var rowShift: Int { Int(swipedRow?.offset ?? 0) }
    var isRowPastCloseLine: Bool { (swipedRow?.offset ?? 0) >= Double(rowWidth) * Self.closeLine }

    private var overscroll: Double { scroll - min(max(scroll, 0), maxScroll) }

    var isCoasting: Bool { !isHeld && (velocity != 0 || overscroll != 0 || isRowSettling) }

    /// A finger took the feed. Returns whether it was still moving on its own.
    @discardableResult
    func hold() -> Bool {
        defer {
            velocity = 0
            isHeld = true
        }
        return isCoasting
    }

    func drag(to position: Double) {
        scroll = min(position, maxScroll + max(position - maxScroll, 0) * Self.dragResistance)
    }

    func release(velocity requested: Double) {
        velocity = min(max(requested, -Self.maxSpeed), Self.maxSpeed)
        isHeld = false
        lastAdvance = nil
    }

    func reset() {
        scroll = 0
        velocity = 0
        isHeld = false
        swipedRow = nil
    }

    func grabRow(_ key: String) {
        let offset = swipedRow?.key == key ? swipedRow?.offset ?? 0 : 0
        swipedRow = SwipedRow(key: key, offsetAtGrab: offset, offset: offset, rest: offset)
    }

    /// `distance` is the drag in cells, negative to the left.
    func dragRow(by distance: Double) {
        guard let row = swipedRow else { return }
        swipedRow?.offset = min(max(row.offsetAtGrab - distance, 0), Double(rowWidth))
    }

    /// Goes by where the row was heading, so a short flick uncovers the button.
    func settleRow(heading distance: Double) {
        guard let row = swipedRow else { return }
        sendRow(to: row.offsetAtGrab - distance < closeButtonWidth / 2 ? 0 : closeButtonWidth)
    }

    /// Returns whether there was a row to cover.
    func coverRow() -> Bool {
        guard swipedRow != nil else { return false }
        sendRow(to: 0)
        return true
    }

    func dropRow() {
        swipedRow = nil
    }

    private func sendRow(to rest: Double) {
        swipedRow?.rest = rest
        if rest == 0, swipedRow?.offset == 0 { swipedRow = nil }
    }

    private func settleRow(over step: TimeInterval) {
        guard let row = swipedRow, isRowSettling else { return }
        let offset = row.offset + (row.rest - row.offset) * (1 - exp(-Self.rowSettleRate * step))
        swipedRow?.offset = abs(row.rest - offset) < Self.settledRowDistance ? row.rest : offset
        if swipedRow?.offset == 0 { swipedRow = nil }
    }

    func advance(to time: TimeInterval) {
        defer { lastAdvance = time }
        guard isCoasting, let lastAdvance else { return }
        var remaining = time - lastAdvance
        while remaining > 0, isCoasting {
            let step = min(remaining, Self.physicsStep)
            simulate(step)
            remaining -= step
        }
    }

    private func simulate(_ step: TimeInterval) {
        settleRow(over: step)
        if overscroll == 0 {
            velocity *= exp(-Self.friction * step)
            if abs(velocity) < Self.stopSpeed { velocity = 0 }
        } else {
            let strength = Self.springStrength
            velocity += (-strength * strength * overscroll - 2 * strength * velocity) * step
        }
        let wasOutside = overscroll != 0
        scroll += velocity * step
        if wasOutside, abs(overscroll) < Self.settledOverscroll, abs(velocity) < Self.stopSpeed {
            scroll -= overscroll
            velocity = 0
        }
    }

    private struct Layout {
        let card: Card
        let sprite: Sprite?
        let titleLines: [String]
        let bodyLines: [String]
        let noteLines: [String]
        let buttons: [(box: Box, index: Int)]
        let height: Int
    }

    private func iconSize(of card: Card, sprite: Sprite?) -> (width: Int, height: Int) {
        if let sprite { return (sprite.width, sprite.height) }
        return card.light == nil ? (0, 0) : (Light.size, Light.size)
    }

    private func layout(_ card: Card, width: Int) -> Layout {
        let sprite = card.sprite?.sprite
        let icon = iconSize(of: card, sprite: sprite)
        let inner = width - 2 * Self.padding
        let iconSpace = icon.width > 0 ? icon.width + Self.iconGap : 0
        let closeSpace = font.glyphWidth + 2
        let titleWidth = inner - iconSpace - closeSpace
        let titleLines = card.light == nil
            ? font.wrap(card.title, width: titleWidth)
            : font.wrap(card.title, width: titleWidth, limit: Self.lightTitleLines)
        let bodyLines = card.text.map { font.wrap($0, width: inner) } ?? []
        let noteLines = card.note.map { font.wrap($0, width: inner) } ?? []

        var y = Self.padding + max(titleLines.count * Scene.lineHeight, icon.height)
        y += (bodyLines.count + noteLines.count) * Scene.lineHeight
        var buttons: [(box: Box, index: Int)] = []
        var x = Self.padding
        for (index, action) in card.actions.enumerated() {
            let buttonWidth = font.width(of: label(for: action)) + 2 * Self.padding
            if buttons.isEmpty {
                y += Self.buttonGap
            } else if x + buttonWidth > width - Self.padding {
                x = Self.padding
                y += Self.buttonHeight + Self.buttonGap
            }
            buttons.append((Box(x: x, y: y, width: buttonWidth, height: Self.buttonHeight), index))
            x += buttonWidth + Self.buttonGap
        }
        if !buttons.isEmpty { y += Self.buttonHeight }

        return Layout(
            card: card,
            sprite: sprite,
            titleLines: titleLines,
            bodyLines: bodyLines,
            noteLines: noteLines,
            buttons: buttons,
            height: y + Self.padding
        )
    }

    private func label(for action: CardAction) -> String {
        switch action.state {
        case .idle: action.label
        case .running: "... \(action.label)"
        case .done: "✓ \(action.label)"
        case .failed: "! \(action.label)"
        }
    }

    private func borderColor(for card: Card) -> Pixel {
        switch card.sprite?.name {
        case "waiting": Palette.yellow
        case "done": Palette.green
        case "error": Palette.red
        case "thinking": Palette.accent
        default: Palette.line
        }
    }

    /// Returns the tappable zones of the visible cards. The feed runs to the screen edge,
    /// and `bottomInset` lets the last card scroll clear of the round bottom corners.
    func draw(
        _ cards: [Card],
        in feed: Box,
        bottomInset: Int,
        rowTarget: (Card) -> Target?,
        dismissTarget: (Card) -> Target?,
        isPinned: (Card) -> Bool,
        time: TimeInterval,
        into buffer: inout Framebuffer
    ) -> [(box: Box, target: Target)] {
        let layouts = cards.map { layout($0, width: feed.width) }
        contentHeight = layouts.reduce(0) { $0 + $1.height + Self.cardGap } - Self.cardGap
        maxScroll = max(0, Double(contentHeight + bottomInset - feed.height))
        rowWidth = feed.width
        if let row = swipedRow, !cards.contains(where: { $0.id == row.key }) { swipedRow = nil }

        var targets: [(box: Box, target: Target)] = []
        let register = { (box: Box, target: Target) in
            if box.maxY > feed.y, box.y < feed.maxY { targets.append((box, target)) }
        }
        // Covers the row that peeks in while the layer sits between two grid rows.
        let visibleBottom = feed.maxY + 1
        var y = feed.y - Int(scroll)
        for card in layouts {
            if y < visibleBottom, y + card.height > feed.y {
                let shift = swipedRow?.key == card.card.id ? rowShift : 0
                if shift > 0 {
                    let row = Box(x: feed.x, y: y, width: feed.width, height: card.height)
                    drawCloseButton(card.card, behind: row, revealed: shift, register: register, into: &buffer)
                }
                draw(card, x: feed.x - shift, y: y, width: feed.width, rowTarget: rowTarget,
                     dismissTarget: dismissTarget, isPinned: isPinned, time: time, register: register,
                     into: &buffer)
            }
            y += card.height + Self.cardGap
        }
        return targets
    }

    private func draw(
        _ layout: Layout,
        x: Int,
        y: Int,
        width: Int,
        rowTarget: (Card) -> Target?,
        dismissTarget: (Card) -> Target?,
        isPinned: (Card) -> Bool,
        time: TimeInterval,
        register: (Box, Target) -> Void,
        into buffer: inout Framebuffer
    ) {
        let frame = Box(x: x, y: y, width: width, height: layout.height)
        buffer.fill(frame, Palette.panel, radius: Self.cornerRadius)
        buffer.stroke(frame, borderColor(for: layout.card), radius: Self.cornerRadius)

        if let target = rowTarget(layout.card) { register(frame, target) }

        let textX = x + Self.padding
        var cursorY = y + Self.padding
        layout.sprite?.draw(at: time, x: textX, y: cursorY, into: &buffer)
        layout.card.light?.draw(at: time, x: textX, y: cursorY + 1, into: &buffer)

        let icon = iconSize(of: layout.card, sprite: layout.sprite)
        let titleX = textX + (icon.width > 0 ? icon.width + Self.iconGap : 0)
        for (index, line) in layout.titleLines.enumerated() {
            let lineY = cursorY + index * Scene.lineHeight
            font.draw(line, x: titleX, y: lineY, color: Palette.text, into: &buffer)
        }
        cursorY += max(layout.titleLines.count * Scene.lineHeight, icon.height)

        for line in layout.bodyLines {
            font.draw(line, x: textX, y: cursorY, color: Palette.dim, into: &buffer)
            cursorY += Scene.lineHeight
        }
        for line in layout.noteLines {
            font.draw(line, x: textX, y: cursorY, color: Palette.red, into: &buffer)
            cursorY += Scene.lineHeight
        }

        for (box, index) in layout.buttons {
            let action = layout.card.actions[index]
            let button = Box(x: x + box.x, y: y + box.y, width: box.width, height: box.height)
            drawButton(action, box: button, into: &buffer)
            if action.state != .running {
                register(button.expanded(by: 3), .action(layout.card, index: index))
            }
        }

        let cornerX = frame.maxX - Self.padding - font.glyphWidth
        if isPinned(layout.card) { drawPin(x: cornerX, y: y + Self.pinInset, into: &buffer) }

        guard let dismiss = dismissTarget(layout.card) else { return }
        font.draw("×", x: cornerX, y: y + 2, color: Palette.dim, into: &buffer)
        let close = Box(x: cornerX, y: y + 2, width: font.glyphWidth, height: Scene.lineHeight)
        register(close.expanded(by: 8), dismiss)
    }

    private func drawPin(x: Int, y: Int, into buffer: inout Framebuffer) {
        for (rowIndex, row) in Self.pin.enumerated() {
            for (columnIndex, cell) in row.enumerated() where cell != "." {
                buffer.plot(x: x + columnIndex, y: y + rowIndex, Palette.accent)
            }
        }
    }

    private func drawCloseButton(
        _ card: Card,
        behind row: Box,
        revealed: Int,
        register: (Box, Target) -> Void,
        into buffer: inout Framebuffer
    ) {
        let button = Box(x: row.maxX - revealed, y: row.y, width: revealed, height: row.height)
        buffer.fill(button, Palette.red, radius: Self.cornerRadius)
        let labelWidth = font.width(of: Self.closeLabel)
        if revealed >= labelWidth {
            font.draw(
                Self.closeLabel,
                x: button.x + (revealed - labelWidth) / 2,
                y: row.y + (row.height - font.glyphHeight) / 2 + 1,
                color: Palette.text,
                into: &buffer
            )
        }
        register(button, .closeChat(key: card.id))
    }

    private func drawButton(_ action: CardAction, box: Box, into buffer: inout Framebuffer) {
        let color = switch action.state {
        case .idle: Palette.accent
        case .running: Palette.dim
        case .done: Palette.green
        case .failed: Palette.red
        }
        buffer.stroke(box, color, radius: Self.buttonCornerRadius)
        font.draw(
            label(for: action),
            x: box.x + Self.padding,
            y: box.y + (box.height - font.glyphHeight) / 2 + 1,
            color: color,
            into: &buffer
        )
    }
}
