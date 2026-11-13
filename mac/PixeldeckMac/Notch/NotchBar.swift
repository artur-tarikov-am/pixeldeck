import CoreGraphics
import Foundation

/// The closed notch: the character on the left wing and the agents at work on the right one,
/// or the sleeping critter there while the hub is away, then a meeting about to start.
/// No wings while all is quiet. For a few seconds after something happens a line of news hangs under it.
@MainActor
final class NotchBar {
    struct Picture {
        var image: CGImage?
        /// Points each wing adds beside the notch.
        var wing: CGFloat
        /// Points the line of news adds under the notch.
        var drop: CGFloat
    }

    /// Cells between the outer edge of a wing and its picture, and the same towards the notch.
    private static let inset = 6
    private static let characterSide = 16
    /// Finished agents only cheer the character up; the wing counts the ones still going or stuck.
    private static let countedLights: Set<Light> = [.waiting, .running, .failed]
    /// Cells the line of news takes under the notch, with the text in its upper part:
    /// the round bottom corners leave less room below.
    private static let newsRows = 15
    private static let newsTop = 2
    private static let lightGap = 3
    /// Wide enough for a line in the middle, so the minutes to a meeting do not read as one more count of agents.
    private static let meetingGap = 13
    /// The line of news widens the notch no further than the open board.
    private static let widestCells = Int((NotchLayout.openWidth - 2 * NotchLayout.closedEar) / Scene.feedPixel)

    private let scene: Scene
    private let news: NotchNews
    private let font = PixelFont.shared
    /// Reconnecting lasts a moment every few seconds while the hub is away, so it does not fold the wings.
    private var isHubAway = false

    init(scene: Scene, news: NotchNews) {
        self.scene = scene
        self.news = news
    }

    func render(deck: Deck, connection: Connection, lastArrival: Date?, now: Date, notch: NotchGeometry) -> Picture {
        switch connection {
        case .online: isHubAway = false
        case .offline: isHubAway = true
        case .connecting: break
        }
        let arrived = scene.isReacting(toArrival: lastArrival, now: now)
        let lights = deck.currentLights
        news.hear(scene.meetings, at: now)
        let item = news.current(at: now)
        let meeting = comingMeeting(at: now)
        let isQuiet = item == nil && meeting == nil && !isHubAway && lights.isEmpty && deck.cards.isEmpty
            && deck.status.mood == "idle" && !arrived
        guard !isQuiet else { return Picture(image: nil, wing: 0, drop: 0) }

        let time = now.timeIntervalSinceReferenceDate
        let counted = lights.filter(Self.countedLights.contains)
        let critter = isHubAway ? SpriteLibrary.named("critter_offline") : nil
        let agentsWidth = critter?.width ?? scene.countsWidth(counted)
        let meetingWidth = meeting.map { Light.size + Self.lightGap + font.width(of: $0.text) } ?? 0
        let meetingX = agentsWidth + (agentsWidth > 0 && meetingWidth > 0 ? Self.meetingGap : 0)
        let rightWidth = meetingX + meetingWidth
        let notchCells = Int((notch.width / Scene.feedPixel).rounded(.up))
        let notchRows = Int(notch.height / Scene.feedPixel)
        var wing = 2 * Self.inset + max(Self.characterSide, rightWidth)
        if let item {
            let needed = (width(of: item) + 2 * Self.inset - notchCells + 1) / 2
            wing = max(wing, min(needed, (Self.widestCells - notchCells) / 2))
        }
        let dropRows = item == nil ? 0 : Self.newsRows
        var buffer = Framebuffer(width: notchCells + 2 * wing, height: notchRows + dropRows)

        let mood = scene.mood(deck: deck, connection: isHubAway ? .offline : .online, arrived: arrived)
        SpriteLibrary.named(mood)?.draw(
            at: time, x: Self.inset, y: (notchRows - Self.characterSide) / 2, into: &buffer
        )
        let rightX = buffer.width - Self.inset - rightWidth
        let textY = (notchRows - font.glyphHeight) / 2
        if let critter {
            critter.draw(at: time, x: rightX, y: (notchRows - critter.height) / 2, into: &buffer)
        } else {
            scene.drawCounts(counted, x: rightX, y: textY, time: time, into: &buffer)
        }
        if let meeting {
            let x = rightX + meetingX
            if meetingX > 0 {
                for row in 1..<font.glyphHeight - 1 {
                    buffer.plot(x: x - (Self.meetingGap + 1) / 2, y: textY + row, Palette.line)
                }
            }
            meeting.light.draw(at: time, x: x, y: textY + 1, into: &buffer)
            font.draw(meeting.text, x: x + Light.size + Self.lightGap, y: textY, color: Palette.text, into: &buffer)
        }
        if let item {
            draw(item, y: notchRows + Self.newsTop, time: time, into: &buffer)
        }
        return Picture(
            image: buffer.makeImage(),
            wing: CGFloat(wing) * Scene.feedPixel,
            drop: CGFloat(dropRows) * Scene.feedPixel
        )
    }

    /// The first meeting due within ten minutes, with the minutes left or "now" when it is time to join.
    private func comingMeeting(at now: Date) -> (light: Light, text: String)? {
        for meeting in scene.meetings {
            guard let phase = meeting.phase(at: now) else { continue }
            switch phase {
            case .soon: return (phase.light, "\(meeting.minutesUntilStart(at: now))m")
            case .starting: return (phase.light, "now")
            case .later, .underway: continue
            }
        }
        return nil
    }

    private func lightWidth(of item: NotchNews.Item) -> Int {
        item.light == nil ? 0 : Light.size + Self.lightGap
    }

    private func width(of item: NotchNews.Item) -> Int {
        lightWidth(of: item) + font.width(of: text(of: item, width: .max))
    }

    /// The name is cut short first, so what happened to it always shows.
    private func text(of item: NotchNews.Item, width: Int) -> String {
        guard let change = item.change else { return font.fit(item.name, width: width) }
        let tail = " " + change
        return font.fit(item.name, width: width - font.width(of: tail)) + tail
    }

    /// Centred under the notch.
    private func draw(_ item: NotchNews.Item, y: Int, time: TimeInterval, into buffer: inout Framebuffer) {
        let lightWidth = lightWidth(of: item)
        let text = text(of: item, width: buffer.width - 2 * Self.inset - lightWidth)
        let x = (buffer.width - lightWidth - font.width(of: text)) / 2
        item.light?.draw(at: time, x: x, y: y + 1, into: &buffer)
        font.draw(text, x: x + lightWidth, y: y, color: Palette.text, into: &buffer)
    }
}

private extension Deck {
    /// What the character reacts to: every session outside Orca and the chats in it at work or just finished.
    var currentLights: [Light] {
        (showsOrca ? orca.filter(\.isCurrent).map(\.light) : []) + (showsClaude ? claude.map(\.light) : [])
    }
}
