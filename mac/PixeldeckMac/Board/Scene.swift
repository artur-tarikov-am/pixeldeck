import CoreGraphics
import Foundation

enum Target {
    case action(Card, index: Int)
    case dismiss(Card)
    case mute(Card)
    case openOnMac(Card)
    case openChat(key: String)
    case closeChat(key: String)
    case openLink(URL)
    case openOrca
    case openClaude
    case openGithub
    case openMeetings
    case back
    case toggle(Integration)
}

enum Screen {
    case board, orca, claude, github, meetings, catalog
}

enum PullState {
    case hidden, pulling, armed, refreshing, succeeded, failed

    fileprivate var spriteName: String {
        switch self {
        case .hidden, .pulling: "idle"
        case .armed: "alert"
        case .refreshing: "thinking"
        case .succeeded: "done"
        case .failed: "error"
        }
    }

    fileprivate func caption(at time: TimeInterval) -> String {
        switch self {
        case .hidden, .pulling: "pull"
        case .armed: "release"
        case .refreshing: String(repeating: ".", count: Int(time * 3) % 3 + 1)
        case .succeeded: "updated"
        case .failed: "failed"
        }
    }
}

private extension Connection {
    /// The critter wears its orange coat only while the Mac is reachable.
    var critterSprite: String {
        switch self {
        case .online: "critter_online"
        case .connecting: "critter_connecting"
        case .offline: "critter_offline"
        }
    }
}

/// The scrolling feed lives in its own layer so it can move between grid rows.
struct Frame {
    var board: CGImage
    /// The clock or the way back and the critter showing the connection, fixed beside the notch while the content moves.
    var header: CGImage?
    /// The screen underneath while a swipe drags the current one away.
    var backdrop: CGImage?
    /// The character shown above the content during pull to refresh.
    var pullIndicator: CGImage?
    var feed: CGImage?
    var feedTop: CGFloat = 0
    var feedHeight: CGFloat = 0
    var feedLayerHeight: CGFloat = 0
    var feedOffset: CGFloat = 0
}

/// What the top agent tile carries for the whole board.
private struct BoardLead {
    var character: String
    var summary: String?
}

/// Draws one whole frame. Everything on screen goes through this low-resolution grid.
@MainActor
final class Scene {
    /// Points per grid cell: 4 and 3 physical pixels on a Retina screen, so edges stay sharp.
    static let boardPixel: CGFloat = 2
    static let feedPixel: CGFloat = 1.5

    static let lineHeight = 11
    private static let margin = 3
    private static let padding = 4
    private static let tileGap = 4
    /// Softens the tiles to match the round corners of the notch.
    static let cornerRadius = 6
    private static let characterScale = 2
    private static let characterSide = 32
    private static let groupLabelWidth = 40
    private static let countGap = 6
    private static let arrivalReaction: TimeInterval = 3
    private static let animationFramesPerSecond = 12.0
    /// The picture changes no faster than this while nothing moves.
    static let idleFrameInterval = 1 / animationFramesPerSecond
    /// The meeting tile leads with the one to join, then the one coming up, then the one in progress.
    private static let meetingLeadOrder: [Meeting.Phase] = [.starting, .soon, .underway, .later]
    private static let indicatorSpriteSide = 16
    private static let indicatorGap = 4
    /// Keeps the header row clear of the rounded screen corners.
    private static let headerSideInset: CGFloat = 16

    private let font = PixelFont.shared
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    let feed = CardFeed()
    private let emptyBoard = EmptyBoard()
    var isRevealingExit = false
    var pullState = PullState.hidden
    /// Hidden while the Mac is closing them, and back if it fails.
    var closingChats: Set<String> = []
    /// Today's meetings from the calendar of the Mac, by start.
    var meetings: [Meeting] = []
    private(set) var screen = Screen.board
    /// How tall the screen has to be to show everything, safe area included,
    /// or nil when it fills whatever it gets. The notch on the Mac sizes itself by it.
    private(set) var contentHeight: CGFloat?
    private var contentRows: Int?
    private var backdrop: CGImage?
    private var pullIndicator: CGImage?
    private var header: CGImage?
    private var boardTargets: [(box: Box, target: Target)] = []
    private var feedTargets: [(box: Box, target: Target)] = []
    private var board: CGImage?
    private var feedLayer: CGImage?
    private var feedTop: CGFloat = 0
    private var feedCards: [Card] = []
    private var drawnAnimationTick: Int?
    private var drawnScrollRow: Int?
    private var drawnRowShift = 0

    /// Every screen has one swipe out: the catalog lies left of the board, the list opens over it.
    private var exit: (screen: Screen, direction: CGFloat) {
        switch screen {
        case .board: (.catalog, 1)
        case .orca, .claude, .github, .meetings: (.board, 1)
        case .catalog: (.board, -1)
        }
    }

    /// The sign of a drag that leaves this screen.
    var exitDirection: CGFloat { exit.direction }

    func leave() {
        show(exit.screen)
    }

    func show(_ screen: Screen) {
        self.screen = screen
        feed.reset()
        drawnAnimationTick = nil
    }

    func target(atX x: CGFloat, y: CGFloat) -> Target? {
        if y >= feedTop {
            let column = Int(x / Self.feedPixel)
            let row = Int((y - feedTop) / Self.feedPixel)
            if let hit = feedTargets.last(where: { $0.box.contains(x: column, y: row) }) {
                return hit.target
            }
        }
        let column = Int(x / Self.boardPixel)
        let row = Int(y / Self.boardPixel)
        return boardTargets.last { $0.box.contains(x: column, y: row) }?.target
    }

    /// The chat a sideways drag would move: to the left it uncovers the button, to the right it covers it again.
    func swipeableChat(atX x: CGFloat, y: CGFloat, dragWidth: CGFloat) -> String? {
        guard screen == .orca else { return nil }
        let key: String
        switch target(atX: x, y: y) {
        case .openChat(let found), .closeChat(let found): key = found
        default: return nil
        }
        guard dragWidth < 0 || key == feed.swipedRow?.key else { return nil }
        return key
    }

    /// The picture itself changes at the animation rate; only the feed follows the finger faster.
    func render(
        deck: Deck,
        connection: Connection,
        lastArrival: Date?,
        now: Date,
        size: CGSize,
        safeTop: CGFloat,
        safeBottom: CGFloat
    ) -> Frame? {
        let time = now.timeIntervalSinceReferenceDate
        feed.advance(to: time)

        let tick = Int(time * Self.animationFramesPerSecond)
        let isNewTick = tick != drawnAnimationTick
        if isNewTick {
            drawnAnimationTick = tick
            drawBoard(deck: deck, connection: connection, lastArrival: lastArrival, now: now,
                      size: size, safeTop: safeTop, time: time)
            pullIndicator = pullState == .hidden ? nil : drawPullIndicator(time: time)
            backdrop = isRevealingExit
                ? drawBackdrop(deck: deck, connection: connection, lastArrival: lastArrival, now: now,
                               size: size, safeTop: safeTop, time: time)
                : nil
        }
        guard let board else { return nil }
        guard !feedCards.isEmpty else {
            feed.reset()
            feedTargets = []
            contentHeight = contentRows.map { CGFloat($0) * Self.boardPixel + safeBottom }
            return Frame(board: board, header: header, backdrop: backdrop, pullIndicator: pullIndicator)
        }

        let rows = Int((size.height - feedTop) / Self.feedPixel)
        if isNewTick || scrollRow != drawnScrollRow || feed.rowShift != drawnRowShift {
            let columns = Int(size.width / Self.feedPixel)
            let inFeedCells = { (boardCells: Int) in
                Int((CGFloat(boardCells) * Self.boardPixel / Self.feedPixel).rounded())
            }
            let boardColumns = Int(size.width / Self.boardPixel)
            var layer = Framebuffer(width: columns, height: rows + 1)
            let screen = self.screen
            let pinned = Set(deck.orca.filter(\.isPinned).map(\.id))
            let links = Dictionary(
                meetings.compactMap { meeting in meeting.link.map { (meeting.key, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            feedTargets = feed.draw(
                feedCards,
                in: Box(
                    x: inFeedCells(Self.margin),
                    y: 0,
                    width: inFeedCells(boardColumns - 2 * Self.margin),
                    height: rows
                ),
                bottomInset: Int((safeBottom / Self.feedPixel).rounded(.up)),
                rowTarget: { card in
                    switch screen {
                    case .orca: .openChat(key: card.id)
                    case .github: .openOnMac(card)
                    case .meetings: links[card.id].map { .openLink($0) }
                    default: nil
                    }
                },
                dismissTarget: { card in
                    switch screen {
                    case .orca, .claude, .meetings: nil
                    case .github: .mute(card)
                    default: .dismiss(card)
                    }
                },
                isPinned: { pinned.contains($0.id) },
                time: time, into: &layer
            )
            drawnScrollRow = scrollRow
            drawnRowShift = feed.rowShift
            feedLayer = layer.makeImage()
        }
        contentHeight = feedTop + CGFloat(feed.contentHeight) * Self.feedPixel + safeBottom
        return Frame(
            board: board,
            header: header,
            backdrop: backdrop,
            pullIndicator: pullIndicator,
            feed: feedLayer,
            feedTop: feedTop,
            feedHeight: CGFloat(rows) * Self.feedPixel,
            feedLayerHeight: CGFloat(rows + 1) * Self.feedPixel,
            feedOffset: (feed.scroll - Double(scrollRow)) * Self.feedPixel
        )
    }

    private var scrollRow: Int { Int(feed.scroll) }

    private func drawPullIndicator(time: TimeInterval) -> CGImage? {
        let captionWidth = font.width(of: "release")
        var buffer = Framebuffer(
            width: Self.indicatorSpriteSide + Self.indicatorGap + captionWidth,
            height: Self.indicatorSpriteSide
        )
        SpriteLibrary.named(pullState.spriteName)?.draw(at: time, x: 0, y: 0, into: &buffer)
        let captionX = Self.indicatorSpriteSide + Self.indicatorGap
        let captionY = (Self.indicatorSpriteSide - font.glyphHeight) / 2
        font.draw(pullState.caption(at: time), x: captionX, y: captionY, color: Palette.dim, into: &buffer)
        return buffer.makeImage()
    }

    private func drawBoard(
        deck: Deck,
        connection: Connection,
        lastArrival: Date?,
        now: Date,
        size: CGSize,
        safeTop: CGFloat,
        time: TimeInterval
    ) {
        var buffer = makeBuffer(size)
        boardTargets = []
        header = drawHeader(connection: connection, now: now, size: size, safeTop: safeTop, time: time)
        let contentTop = headerRows(safeTop: safeTop)

        let feedRow: Int
        switch screen {
        case .board:
            let tiles = drawTiles(deck: deck, connection: connection, lastArrival: lastArrival,
                                  now: now, time: time, top: contentTop, into: &buffer)
            boardTargets = tiles.targets
            feedRow = tiles.nextRow
            feedCards = deck.cards
            contentRows = isBlank(deck, at: now) ? nil : tiles.nextRow - Self.tileGap
        case .orca:
            boardTargets = backTarget(boardWidth: buffer.width, headerRows: contentTop)
            feedRow = contentTop
            let chats = deck.orca.filter { !closingChats.contains($0.id) }
            feedCards = (chats.filter(\.isPinned) + chats.filter { !$0.isPinned }).map(\.card)
            contentRows = contentTop
        case .claude:
            boardTargets = backTarget(boardWidth: buffer.width, headerRows: contentTop)
            feedRow = contentTop
            feedCards = deck.claude.map(\.card)
            contentRows = contentTop
        case .github:
            boardTargets = backTarget(boardWidth: buffer.width, headerRows: contentTop)
            feedRow = contentTop
            feedCards = deck.github.map(\.card)
            contentRows = contentTop
        case .meetings:
            boardTargets = backTarget(boardWidth: buffer.width, headerRows: contentTop)
            feedRow = contentTop
            feedCards = meetingsLeft(at: now).map { meetingCard($0.meeting, phase: $0.phase, now: now) }
            contentRows = contentTop
        case .catalog:
            boardTargets = drawCatalog(deck: deck, time: time, top: contentTop, into: &buffer)
            feedRow = contentTop
            feedCards = []
            contentRows = boardTargets.last?.box.maxY ?? contentTop
        }
        feedTop = CGFloat(feedRow) * Self.boardPixel
        board = buffer.makeImage()
    }

    /// The label is too small to aim at, so the whole corner beside the notch takes the tap.
    private func backTarget(boardWidth: Int, headerRows: Int) -> [(box: Box, target: Target)] {
        [(Box(x: 0, y: 0, width: boardWidth / 2, height: headerRows), .back)]
    }

    private func drawBackdrop(
        deck: Deck,
        connection: Connection,
        lastArrival: Date?,
        now: Date,
        size: CGSize,
        safeTop: CGFloat,
        time: TimeInterval
    ) -> CGImage? {
        var buffer = makeBuffer(size)
        let top = headerRows(safeTop: safeTop)
        if exit.screen == .catalog {
            _ = drawCatalog(deck: deck, time: time, top: top, into: &buffer)
        } else {
            _ = drawTiles(deck: deck, connection: connection, lastArrival: lastArrival,
                          now: now, time: time, top: top, into: &buffer)
        }
        return buffer.makeImage()
    }

    private func makeBuffer(_ size: CGSize) -> Framebuffer {
        Framebuffer(width: Int(size.width / Self.boardPixel), height: Int(size.height / Self.boardPixel))
    }

    /// Returns the row below the tiles and their tap zones.
    private func drawTiles(
        deck: Deck,
        connection: Connection,
        lastArrival: Date?,
        now: Date,
        time: TimeInterval,
        top: Int,
        into buffer: inout Framebuffer
    ) -> (nextRow: Int, targets: [(box: Box, target: Target)]) {
        if isBlank(deck, at: now) {
            emptyBoard.draw(time: time, top: top, into: &buffer)
            return (top, [])
        }
        let arrived = isReacting(toArrival: lastArrival, now: now)
        var nextRow = top
        var targets: [(box: Box, target: Target)] = []
        if deck.showsOrca {
            let lights = deck.orca.map(\.light)
            let tile = drawAgents(
                "ORCA", lights: lights,
                lead: boardLead(deck: deck, lights: lights, connection: connection, arrived: arrived),
                time: time, top: nextRow, into: &buffer
            )
            targets.append((tile, .openOrca))
            nextRow = tile.maxY + Self.tileGap
        }
        if deck.showsClaude {
            let lights = deck.claude.map(\.light)
            let lead = deck.showsOrca
                ? nil
                : boardLead(deck: deck, lights: lights, connection: connection, arrived: arrived)
            let tile = drawAgents("CLAUDE", lights: lights, lead: lead, time: time, top: nextRow, into: &buffer)
            targets.append((tile, .openClaude))
            nextRow = tile.maxY + Self.tileGap
        }
        if deck.showsGithub {
            let tile = drawGithub(deck: deck, connection: connection, time: time, top: nextRow, into: &buffer)
            targets.append((tile, .openGithub))
            nextRow = tile.maxY + Self.tileGap
        }
        let meetings = meetingsLeft(at: now)
        if let lead = Self.meetingLeadOrder.lazy.compactMap({ phase in meetings.first { $0.phase == phase } }).first {
            let tile = drawMeetings(lead: lead, count: meetings.count, now: now, time: time, top: nextRow, into: &buffer)
            targets.append((tile, .openMeetings))
            nextRow = tile.maxY + Self.tileGap
        }
        return (nextRow, targets)
    }

    /// The board goes to the character only while no meeting is left today either.
    private func isBlank(_ deck: Deck, at now: Date) -> Bool {
        deck.isBlank && meetingsLeft(at: now).isEmpty
    }

    // MARK: Catalog

    /// Returns one tap zone per integration.
    private func drawCatalog(
        deck: Deck,
        time: TimeInterval,
        top: Int,
        into buffer: inout Framebuffer
    ) -> [(box: Box, target: Target)] {
        font.draw("INTEGRATIONS", x: Self.margin, y: top, color: Palette.accent, into: &buffer)
        var targets: [(box: Box, target: Target)] = []
        var y = top + Self.lineHeight + Self.tileGap
        for integration in deck.integrations {
            let tile = drawIntegration(integration, y: y, time: time, into: &buffer)
            targets.append((tile, .toggle(integration)))
            y = tile.maxY + Self.tileGap
        }
        return targets
    }

    private func drawIntegration(
        _ integration: Integration,
        y: Int,
        time: TimeInterval,
        into buffer: inout Framebuffer
    ) -> Box {
        let width = buffer.width - 2 * Self.margin
        let lines = font.wrap(integration.text, width: width - 2 * Self.padding)
        let height = 2 * Self.padding + (lines.count + 1) * Self.lineHeight
        let tile = Box(x: Self.margin, y: y, width: width, height: height)
        let x = Self.margin + Self.padding
        let titleY = y + Self.padding

        buffer.fill(tile, Palette.panel, radius: Self.cornerRadius)
        buffer.stroke(tile, Palette.line, radius: Self.cornerRadius)
        let light = integration.isOn ? Light.done : Light.idle
        light.draw(at: time, x: x, y: titleY + 1, into: &buffer)
        font.draw(
            integration.title,
            x: x + Light.size + 3,
            y: titleY,
            color: integration.isOn ? Palette.accent : Palette.dim,
            into: &buffer
        )
        let state = integration.isOn ? "on" : "off"
        font.draw(state, x: tile.maxX - Self.padding - font.width(of: state), y: titleY, color: Palette.dim, into: &buffer)
        for (index, line) in lines.enumerated() {
            font.draw(line, x: x, y: titleY + (index + 1) * Self.lineHeight, color: Palette.dim, into: &buffer)
        }
        return tile
    }

    // MARK: Header

    /// The board row where the content starts.
    private func headerRows(safeTop: CGFloat) -> Int {
        Int((safeTop / Self.boardPixel).rounded(.up))
    }

    private var backLabel: String? {
        switch screen {
        case .orca: "< ORCA"
        case .claude: "< CLAUDE"
        case .github: "< GITHUB"
        case .meetings: "< MEETINGS"
        case .board, .catalog: nil
        }
    }

    /// Uses the finer grid of the feed, so the critter stays small enough for the strip beside the notch.
    private func drawHeader(
        connection: Connection,
        now: Date,
        size: CGSize,
        safeTop: CGFloat,
        time: TimeInterval
    ) -> CGImage? {
        var buffer = Framebuffer(
            width: Int(size.width / Self.feedPixel),
            height: Int(safeTop / Self.feedPixel)
        )
        let inset = Int(Self.headerSideInset / Self.feedPixel)
        let textY = (buffer.height - font.glyphHeight) / 2
        if let backLabel {
            font.draw(backLabel, x: inset, y: textY, color: Palette.accent, into: &buffer)
        } else {
            font.draw(clock.string(from: now), x: inset, y: textY, color: Palette.text, into: &buffer)
        }
        if let critter = SpriteLibrary.named(connection.critterSprite) {
            critter.draw(
                at: time, x: buffer.width - inset - critter.width, y: (buffer.height - critter.height) / 2,
                into: &buffer
            )
        }
        return buffer.makeImage()
    }

    // MARK: Agents

    func isReacting(toArrival lastArrival: Date?, now: Date) -> Bool {
        lastArrival.map { now.timeIntervalSince($0) < Self.arrivalReaction } ?? false
    }

    /// The sprite of the character.
    func mood(deck: Deck, connection: Connection, arrived: Bool) -> String {
        guard connection == .online else { return "sleep" }
        if arrived { return "alert" }
        if deck.status.mood != "idle" { return deck.status.mood }
        return deck.cards.contains { $0.sprite?.name == "waiting" } ? "waiting" : "idle"
    }

    /// Nothing to say while the counts speak for themselves.
    private func boardSummary(deck: Deck, lights: [Light], connection: Connection) -> String? {
        switch connection {
        case .connecting, .offline: "waiting for hub"
        case .online: deck.status.text ?? (lights.isEmpty ? "quiet" : nil)
        }
    }

    private func boardLead(deck: Deck, lights: [Light], connection: Connection, arrived: Bool) -> BoardLead {
        BoardLead(
            character: mood(deck: deck, connection: connection, arrived: arrived),
            summary: boardSummary(deck: deck, lights: lights, connection: connection)
        )
    }

    /// The top agent tile leads the board; below it a tile is only a title and the counts.
    private func drawAgents(
        _ title: String,
        lights: [Light],
        lead: BoardLead?,
        time: TimeInterval,
        top: Int,
        into buffer: inout Framebuffer
    ) -> Box {
        let width = buffer.width - 2 * Self.margin
        let inner = width - 2 * Self.padding
        let x = Self.margin + Self.padding
        let height = 2 * Self.padding + (lead == nil ? 2 * Self.lineHeight : Self.characterSide)
        let tile = Box(x: Self.margin, y: top, width: width, height: height)

        buffer.fill(tile, Palette.panel, radius: Self.cornerRadius)
        buffer.stroke(tile, lights.contains(.waiting) ? Palette.yellow : Palette.line, radius: Self.cornerRadius)
        font.draw(title, x: x, y: top + Self.padding, color: Palette.accent, into: &buffer)
        var y = top + Self.padding + Self.lineHeight
        if let summary = lead?.summary {
            let line = font.fit(summary, width: inner - Self.characterSide - Self.padding)
            font.draw(line, x: x, y: y, color: Palette.dim, into: &buffer)
            y += Self.lineHeight
        }
        drawCounts(lights, x: x, y: y, time: time, into: &buffer)

        if let lead { drawCharacter(lead.character, in: tile, time: time, into: &buffer) }
        return tile
    }

    private func drawCharacter(_ name: String, in tile: Box, time: TimeInterval, into buffer: inout Framebuffer) {
        SpriteLibrary.named(name)?.draw(
            at: time,
            x: tile.maxX - Self.padding - Self.characterSide,
            y: tile.y + Self.padding,
            scale: Self.characterScale,
            into: &buffer
        )
    }

    /// A light and a number for each state that has anything in it, most urgent first.
    func drawCounts(
        _ lights: [Light],
        x: Int,
        y: Int,
        time: TimeInterval,
        into buffer: inout Framebuffer
    ) {
        for count in counts(lights) {
            count.light.draw(at: time, x: x + count.lightX, y: y + 1, into: &buffer)
            font.draw(count.number, x: x + count.numberX, y: y, color: Palette.text, into: &buffer)
        }
    }

    func countsWidth(_ lights: [Light]) -> Int {
        counts(lights).last.map { $0.numberX + font.width(of: $0.number) } ?? 0
    }

    private func counts(_ lights: [Light]) -> [(light: Light, lightX: Int, number: String, numberX: Int)] {
        var counts: [(light: Light, lightX: Int, number: String, numberX: Int)] = []
        var x = 0
        for light in Light.byUrgency {
            let count = lights.filter { $0 == light }.count
            guard count > 0 else { continue }
            let number = String(count)
            let numberX = x + Light.size + 3
            counts.append((light, x, number, numberX))
            x = numberX + font.width(of: number) + Self.countGap
        }
        return counts
    }

    // MARK: GitHub

    private func octopusSprite(deck: Deck, connection: Connection) -> String {
        guard connection == .online else { return "octopus_asleep" }
        let lights = deck.github.map(\.light)
        let light = Light.byUrgency.first { lights.contains($0) } ?? .idle
        return "octopus_\(light.rawValue)"
    }

    private func drawGithub(
        deck: Deck,
        connection: Connection,
        time: TimeInterval,
        top: Int,
        into buffer: inout Framebuffer
    ) -> Box {
        let width = buffer.width - 2 * Self.margin
        let x = Self.margin + Self.padding
        let groups: [(label: String, items: [GithubItem])] = [
            ("mine", deck.github.filter { $0.group == .mine }),
            ("review", deck.github.filter { $0.group == .review }),
        ]
        let height = 2 * Self.padding + (groups.count + 1) * Self.lineHeight
        let tile = Box(x: Self.margin, y: top, width: width, height: height)

        buffer.fill(tile, Palette.panel, radius: Self.cornerRadius)
        buffer.stroke(tile, Palette.line, radius: Self.cornerRadius)
        font.draw("GITHUB", x: x, y: top + Self.padding, color: Palette.accent, into: &buffer)

        var y = top + Self.padding + Self.lineHeight
        for group in groups {
            font.draw(group.label, x: x, y: y, color: Palette.dim, into: &buffer)
            drawCounts(group.items.map(\.light), x: x + Self.groupLabelWidth, y: y, time: time, into: &buffer)
            y += Self.lineHeight
        }
        drawCharacter(octopusSprite(deck: deck, connection: connection), in: tile, time: time, into: &buffer)
        return tile
    }

    // MARK: Meetings

    private func meetingsLeft(at now: Date) -> [(meeting: Meeting, phase: Meeting.Phase)] {
        meetings.compactMap { meeting in meeting.phase(at: now).map { (meeting, $0) } }
    }

    private func meetingStatus(_ meeting: Meeting, phase: Meeting.Phase, now: Date) -> String {
        switch phase {
        case .later: clock.string(from: meeting.start)
        case .soon: "in \(meeting.minutesUntilStart(at: now))m"
        case .starting: "now"
        case .underway: "\(meeting.minutesLeft(at: now))m left"
        }
    }

    private func meetingCard(_ meeting: Meeting, phase: Meeting.Phase, now: Date) -> Card {
        var details = ["\(clock.string(from: meeting.start))–\(clock.string(from: meeting.end))"]
        if phase != .later { details.append(meetingStatus(meeting, phase: phase, now: now)) }
        if meeting.link == nil { details.append("no link") }
        return Card(
            id: meeting.key, title: meeting.title, text: details.joined(separator: " · "),
            light: phase.light, actions: []
        )
    }

    /// The meeting most worth a glance and how many more are left today.
    private func drawMeetings(
        lead: (meeting: Meeting, phase: Meeting.Phase),
        count: Int,
        now: Date,
        time: TimeInterval,
        top: Int,
        into buffer: inout Framebuffer
    ) -> Box {
        let width = buffer.width - 2 * Self.margin
        let x = Self.margin + Self.padding
        let height = 2 * Self.padding + 2 * Self.lineHeight
        let tile = Box(x: Self.margin, y: top, width: width, height: height)

        buffer.fill(tile, Palette.panel, radius: Self.cornerRadius)
        buffer.stroke(tile, lead.phase == .starting ? Palette.yellow : Palette.line, radius: Self.cornerRadius)
        font.draw("MEETINGS", x: x, y: top + Self.padding, color: Palette.accent, into: &buffer)
        if count > 1 {
            let more = "+\(count - 1) today"
            let moreX = tile.maxX - Self.padding - font.width(of: more)
            font.draw(more, x: moreX, y: top + Self.padding, color: Palette.dim, into: &buffer)
        }

        let y = top + Self.padding + Self.lineHeight
        lead.phase.light.draw(at: time, x: x, y: y + 1, into: &buffer)
        let status = meetingStatus(lead.meeting, phase: lead.phase, now: now)
        let statusX = tile.maxX - Self.padding - font.width(of: status)
        let titleX = x + Light.size + 3
        let title = font.fit(lead.meeting.title, width: statusX - Self.countGap - titleX)
        font.draw(title, x: titleX, y: y, color: Palette.text, into: &buffer)
        font.draw(status, x: statusX, y: y, color: Palette.dim, into: &buffer)
        return tile
    }
}
