/// Draws the README pictures of the board and the notch with the app's own code, on made-up data:
/// the live board shows work chats and pull requests that do not belong on a public page.
///
/// Usage (needs ffmpeg):
///   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -o "$TMPDIR/make_readme_images" \
///     tools/make_readme_images.swift mac/PixeldeckMac/Board/*.swift \
///     mac/PixeldeckMac/Notch/{NotchBar,NotchNews,NotchGeometry,CharacterPresence,Skit}.swift
///   cp mac/PixeldeckMac/Board/Resources/*.json "$TMPDIR"
///   "$TMPDIR/make_readme_images" docs/images
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum MakeReadmeImages {
    static func main() {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        writeHero(to: folder)
        writeLists(to: folder)
        writeNews(to: folder)
        writeDeparture(to: folder)
    }

    /// The open board, looping over its idle animation.
    static func writeHero(to folder: URL) {
        let scene = Scene()
        scene.meetings = Sample.meetings
        let deck = Sample.deck(cards: Sample.cards, status: Status(mood: "idle", text: "caching forecasts"))
        // 75 frames last about as long as three breaths of the orange light, so the loop has no visible seam.
        let frames = (0..<75).map { frame in
            OpenNotch.draw(scene: scene, deck: deck, now: Timeline.frame(frame), sky: CGSize(width: 1600, height: 1080))
        }
        writeGIF(frames, to: folder.appendingPathComponent("hero.gif"))
    }

    static func writeLists(to folder: URL) {
        for (name, screen) in [("orca", Screen.orca), ("github", .github), ("meetings", .meetings), ("catalog", .catalog)] {
            let scene = Scene()
            scene.meetings = Sample.meetings
            scene.show(screen)
            let deck = Sample.deck(cards: Sample.cards, integrations: Sample.integrations)
            writePNG(OpenNotch.draw(scene: scene, deck: deck, now: Timeline.brightLights, sky: nil),
                     to: folder.appendingPathComponent("\(name).png"))
        }
    }

    /// Counts and a meeting on the wings, then three lines of news one after another.
    static func writeNews(to folder: URL) {
        let meeting = Meeting(key: "design", title: "Design review", start: Timeline.at(6.5 * 60), end: Timeline.at(48 * 60))
        let notch = ClosedNotch(
            deck: Sample.deck(orca: Sample.chats(releaseNotes: .running), github: Sample.pullRequests(withMention: false)),
            meetings: [meeting]
        )
        notch.callCharacter(at: -8)
        let changes = [
            18: Sample.deck(github: Sample.pullRequests(withMention: false)),
            30: Sample.deck(github: Sample.pullRequests(cacheApprovedBy: ["anna"], withMention: false)),
            42: Sample.deck(github: Sample.pullRequests(cacheApprovedBy: ["anna"])),
        ]
        let frames = (0..<138).map { frame in
            if let next = changes[frame] { notch.change(to: next) }
            return notch.draw(at: Timeline.frame(frame))
        }
        writeGIF(frames, to: folder.appendingPathComponent("closed.gif"))
    }

    /// The wings show the same for three minutes: the character leaves and the counts dim.
    /// Then an agent finishes and it comes back. The skits are drawn at random, so this tries
    /// until the moonwalk and the fall from above come up, telling them by their length.
    static func writeDeparture(to folder: URL) {
        let leavingSkit: TimeInterval = 3.0
        let arrivingSkit: TimeInterval = 2.2
        let agentFinishes = 84
        let start = TimeInterval(CharacterPresence.defaultSeconds) - 1
        for _ in 1...2000 {
            let notch = ClosedNotch(deck: Sample.deck(github: []), meetings: [])
            notch.callCharacter(at: 0)
            var skits: [TimeInterval] = []
            var wings: [ClosedNotch.Moment] = []
            for frame in 0..<138 {
                if frame == agentFinishes { notch.change(to: Sample.deck(orca: Sample.chats(flakyTests: .done), github: [])) }
                let now = Timeline.frame(frame, from: start)
                if case let .playing(skit, _) = notch.presence.stage(at: now), skits.last != skit.duration {
                    skits.append(skit.duration)
                }
                wings.append(notch.moment(at: now))
            }
            if skits.count == 2, zip(skits, [leavingSkit, arrivingSkit]).allSatisfy({ abs($0 - $1) < 0.01 }) {
                writeGIF(wings.map { ClosedNotch.draw($0) }, to: folder.appendingPathComponent("away.gif"))
                return
            }
        }
        fatalError("the moonwalk and the fall never came up together")
    }
}

// MARK: - Time

enum Timeline {
    static let framesPerSecond = 12.0
    static let start = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 10, minute: 42))!

    static func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Mid-tick, so every frame lands on a tick of its own in `Scene`.
    static func frame(_ index: Int, from seconds: TimeInterval = 0) -> Date {
        at(seconds + (Double(index) + 0.5) / framesPerSecond)
    }

    /// The orange light at the top of its breath and the yellow one lit, for the still pictures.
    static let brightLights: Date = {
        let base = start.timeIntervalSinceReferenceDate
        let offset = stride(from: 0.0, to: 3, by: 1.0 / 120)
            .filter { (base + $0).truncatingRemainder(dividingBy: 1) < 0.5 }
            .max { sin(3 * (base + $0)) < sin(3 * (base + $1)) }!
        return at(offset)
    }()
}

// MARK: - Made-up board

enum Sample {
    /// In the order the hub sends them: waiting, running, failed, the rest.
    static func chats(releaseNotes: Light = .done, flakyTests: Light = .running) -> [OrcaSession] {
        [
            chat("cold", "Profile the cold launch", .done, project: "weather-app", isCurrent: false, isPinned: true),
            chat("charts", "Charts for the stats screen", .waiting, project: "weather-app",
                 question: "Swift Charts or a custom view?"),
            chat("cache", "Cache forecasts for offline use", .running, project: "weather-app"),
            chat("flaky", "Fix the flaky snapshot tests", flakyTests, provider: "codex", project: "weather-app"),
            chat("runners", "Move CI to the new macOS runners", .failed, project: "dotfiles"),
            chat("notes", "Release notes for 2.4", releaseNotes, project: "blog"),
            chat("zsh", "Tidy up the zsh config", .done, project: "dotfiles", isCurrent: false),
        ]
    }

    private static func chat(
        _ id: String, _ title: String, _ light: Light, provider: String = "claude", project: String,
        question: String? = nil, isCurrent: Bool = true, isPinned: Bool = false
    ) -> OrcaSession {
        OrcaSession(id: id, provider: provider, project: project, title: title, light: light, question: question,
                    isCurrent: isCurrent, isPinned: isPinned)
    }

    /// Mentions first, as the hub sends them.
    static func pullRequests(cacheApprovedBy: [String] = [], withMention: Bool = true) -> [GithubItem] {
        let mention = GithubItem(key: "mention-221", group: .mention, light: .waiting, title: "#221 Offline map tiles",
                                 text: "anna: @leo-p does this cover the widget too?")
        let cacheReview = cacheApprovedBy.isEmpty ? "awaiting review" : "approved by \(cacheApprovedBy.joined(separator: ", "))"
        return (withMention ? [mention] : []) + [
            GithubItem(key: "205", group: .mine, light: .waiting, title: "#205 Retry uploads after a timeout",
                       text: "CI ok, changes requested", approvedBy: []),
            GithubItem(key: "214", group: .mine, light: .running, title: "#214 Cache forecasts for offline use",
                       text: "CI running, \(cacheReview)", approvedBy: cacheApprovedBy),
            GithubItem(key: "209", group: .mine, light: .done, title: "#209 Dark mode for the settings screen",
                       text: "CI ok, approved by nadia-dev", approvedBy: ["nadia-dev"]),
            GithubItem(key: "198", group: .review, light: .review, title: "#198 Bump swift-format to 601",
                       text: "review for nadia-dev"),
            GithubItem(key: "87", group: .review, light: .review, title: "#87 Translate the onboarding into Serbian",
                       text: "review for tomas-k"),
        ]
    }

    static let cards = [
        Card(id: "deploy", title: "Deploy weather-app to staging?", text: "Build 2.4.0 (318) passed all checks.",
             sprite: .named("waiting"),
             actions: [CardAction(label: "Deploy", state: .idle), CardAction(label: "Not now", state: .idle)]),
        Card(id: "nightly", title: "Nightly build is on TestFlight", text: "2.4.0 (318), took 14m 02s",
             sprite: .named("done"),
             actions: [CardAction(label: "Open", url: URL(string: "https://example.com"), state: .idle)]),
    ]

    static let integrations = [
        Integration(id: "orca", title: "ORCA", text: "chats and agent terminals in Orca, of any provider", isOn: true),
        Integration(id: "claude", title: "CLAUDE", text: "Claude Code sessions outside Orca", isOn: false),
        Integration(id: "github", title: "GITHUB", text: "your pull requests, review requests and mentions", isOn: true),
    ]

    static let meetings = [
        Meeting(key: "design", title: "Design review", start: Timeline.at(7 * 60), end: Timeline.at(48 * 60),
                link: URL(string: "https://example.com/call")),
        Meeting(key: "sync", title: "Weekly sync", start: Timeline.at(198 * 60), end: Timeline.at(228 * 60),
                link: URL(string: "https://example.com/call")),
        Meeting(key: "planning", title: "Planning for 2.5", start: Timeline.at(318 * 60), end: Timeline.at(363 * 60)),
    ]

    static func deck(
        orca: [OrcaSession] = chats(),
        github: [GithubItem] = pullRequests(),
        cards: [Card] = [],
        status: Status = Status(mood: "idle", text: nil),
        integrations: [Integration] = []
    ) -> Deck {
        Deck(cards: cards, status: status, orca: orca, claude: [], github: github, integrations: integrations)
    }
}

// MARK: - Notch

/// The camera housing of a 14-inch MacBook Pro.
let notchGeometry = NotchGeometry(width: 200, height: 32)
/// Image pixels per point, as on a Retina screen.
let scale: CGFloat = 2

extension NotchGeometry {
    init(width: CGFloat, height: CGFloat) {
        midX = 0
        top = 0
        self.width = width
        self.height = height
        maxOpenHeight = 600
    }
}

/// The open notch laid out as `NotchView` lays it out, alone or hanging over a sky.
enum OpenNotch {
    static func draw(scene: Scene, deck: Deck, now: Date, sky: CGSize?) -> CGImage {
        let size = CGSize(width: NotchLayout.boardWidth, height: notchGeometry.maxOpenHeight)
        guard let frame = scene.render(
            deck: deck, connection: .online, lastArrival: nil, now: now, size: size,
            safeTop: notchGeometry.height, safeBottom: NotchLayout.bottomInset
        ) else { fatalError("the scene drew nothing") }
        let height = max(min(size.height, scene.contentHeight ?? size.height), notchGeometry.height)
        let shape = CGSize(width: NotchLayout.openWidth * scale, height: height * scale)
        let canvas = ImageCanvas(size: sky ?? shape)
        if sky != nil { canvas.drawSky(down: 1) }
        let shapeX = (canvas.size.width - shape.width) / 2
        let path = canvas.notchPath(
            x: shapeX, size: shape, ear: NotchLayout.openEar * scale, radius: NotchLayout.openRadius * scale
        )
        canvas.fill(path, shadow: sky != nil)
        canvas.clipped(to: path) {
            let boardX = shapeX + NotchLayout.openEar * scale
            canvas.draw(frame.board, x: boardX, top: 0, cell: Scene.boardPixel * scale)
            if let feed = frame.feed {
                let feedTop = frame.feedTop * scale
                let visible = CGRect(x: boardX, y: feedTop, width: NotchLayout.boardWidth * scale,
                                     height: frame.feedHeight * scale)
                canvas.clipped(to: visible) {
                    canvas.draw(feed, x: boardX, top: feedTop - frame.feedOffset * scale, cell: Scene.feedPixel * scale)
                }
            }
            if let header = frame.header {
                canvas.draw(header, x: boardX, top: 0, cell: Scene.feedPixel * scale)
            }
        }
        return canvas.image
    }
}

/// The closed notch as `WingsView` draws it twelve times a second, and the shape around it as `NotchView` animates it.
final class ClosedNotch {
    struct Moment {
        var picture: CGImage?
        var shape: CGSize
        var ear: CGFloat
    }

    let presence = CharacterPresence()
    private let scene = Scene()
    private let news = NotchNews()
    private lazy var bar = NotchBar(scene: scene, news: news, presence: presence)
    private var deck: Deck
    private var shape: (size: CGSize, ear: CGFloat)?

    private static let sky: CGImage = {
        let canvas = ImageCanvas(size: CGSize(width: 1200, height: 150))
        canvas.drawSky(down: 0.22)
        return canvas.image
    }()

    init(deck: Deck, meetings: [Meeting]) {
        self.deck = deck
        scene.meetings = meetings
    }

    /// Brings the character onto the wing at `seconds` and lets its arrival play out,
    /// so the pictures that follow start with it in place.
    func callCharacter(at seconds: TimeInterval) {
        for second in stride(from: seconds, to: seconds + 8, by: 1) { _ = bar.render(at: Timeline.at(second), deck: deck) }
    }

    func change(to next: Deck) {
        news.hear(old: deck, new: next)
        deck = next
    }

    func moment(at now: Date) -> Moment {
        let picture = bar.render(at: now, deck: deck)
        let ear = picture.wing > 0 ? NotchLayout.closedEar : 0
        let target = CGSize(width: notchGeometry.width + 2 * (picture.wing + ear), height: notchGeometry.height + picture.drop)
        // Close enough to the spring of `NotchView` at twelve frames a second.
        let follow: CGFloat = shape == nil ? 1 : 0.6
        let last = shape ?? (target, ear)
        shape = (
            CGSize(width: last.size.width + (target.width - last.size.width) * follow,
                   height: last.size.height + (target.height - last.size.height) * follow),
            last.ear + (ear - last.ear) * follow
        )
        return Moment(picture: picture.image, shape: shape!.size, ear: shape!.ear)
    }

    func draw(at now: Date) -> CGImage {
        Self.draw(moment(at: now))
    }

    static func draw(_ moment: Moment) -> CGImage {
        let canvas = ImageCanvas(size: CGSize(width: sky.width, height: sky.height))
        canvas.draw(sky, x: 0, top: 0, cell: 1)
        let shape = CGSize(width: moment.shape.width * scale, height: moment.shape.height * scale)
        let path = canvas.notchPath(
            x: (canvas.size.width - shape.width) / 2, size: shape,
            ear: moment.ear * scale, radius: NotchLayout.closedRadius * scale
        )
        canvas.fill(path, shadow: false)
        if let picture = moment.picture {
            let cell = Scene.feedPixel * scale
            canvas.clipped(to: path) {
                canvas.draw(picture, x: (canvas.size.width - CGFloat(picture.width) * cell) / 2, top: 0, cell: cell)
            }
        }
        return canvas.image
    }
}

private extension NotchBar {
    func render(at now: Date, deck: Deck) -> Picture {
        render(deck: deck, connection: .online, lastArrival: nil, now: now, notch: notchGeometry)
    }
}

// MARK: - Drawing

/// A picture in image pixels, measured from the top left corner like the board.
final class ImageCanvas {
    let size: CGSize
    private let context: CGContext

    init(size: CGSize) {
        self.size = size
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("cannot draw \(size)") }
        context.interpolationQuality = .none
        self.context = context
    }

    var image: CGImage {
        guard let image = context.makeImage() else { fatalError("cannot make an image") }
        return image
    }

    /// Core Graphics counts from the bottom.
    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func flipped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: size.height - point.y)
    }

    /// Each cell of `image` becomes a `cell`-wide square.
    func draw(_ image: CGImage, x: CGFloat, top: CGFloat, cell: CGFloat) {
        let rect = CGRect(x: x, y: top, width: CGFloat(image.width) * cell, height: CGFloat(image.height) * cell)
        context.draw(image, in: flipped(rect))
    }

    func clipped(to path: CGPath, _ draw: () -> Void) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        draw()
        context.restoreGState()
    }

    func clipped(to rect: CGRect, _ draw: () -> Void) {
        clipped(to: CGPath(rect: flipped(rect), transform: nil), draw)
    }

    func fill(_ path: CGPath, shadow: Bool) {
        context.saveGState()
        if shadow {
            context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
        }
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()
    }

    /// `NotchShape` hanging from the top edge.
    func notchPath(x: CGFloat, size shape: CGSize, ear: CGFloat, radius: CGFloat) -> CGPath {
        let rect = CGRect(x: x, y: 0, width: shape.width, height: shape.height)
        let body = rect.insetBy(dx: ear, dy: 0)
        let radius = min(radius, body.width / 2, body.height - ear)
        let corners = [
            (CGPoint(x: body.minX, y: rect.minY), CGPoint(x: body.minX, y: body.maxY), ear),
            (CGPoint(x: body.minX, y: body.maxY), CGPoint(x: body.maxX, y: body.maxY), radius),
            (CGPoint(x: body.maxX, y: body.maxY), CGPoint(x: body.maxX, y: rect.minY), radius),
            (CGPoint(x: body.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), ear),
        ]
        let path = CGMutablePath()
        path.move(to: flipped(CGPoint(x: rect.minX, y: rect.minY)))
        for (corner, next, radius) in corners where radius > 0 {
            path.addArc(tangent1End: flipped(corner), tangent2End: flipped(next), radius: radius)
        }
        path.addLine(to: flipped(CGPoint(x: rect.maxX, y: rect.minY)))
        path.closeSubpath()
        return path
    }

    /// A dusk sky in dithered dots, the canvas showing its top `down` of it.
    func drawSky(down: Double) {
        let stops: [UInt32] = [0x231C3A, 0x3A2A58, 0x6A3C6E, 0xA9546B, 0xD9774F, 0xEFA35E]
        let bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
        let cell = 8, dot = 6
        let rows = Int(size.height) / cell + 1, columns = Int(size.width) / cell + 1
        for row in 0..<rows {
            let share = down * (Double(row) + 0.5) / Double(rows)
            let position = min(share, 0.9999) * Double(stops.count - 1)
            let index = Int(position)
            for column in 0..<columns {
                let cellRect = CGRect(x: column * cell, y: row * cell, width: cell, height: cell)
                context.setFillColor(color(stops[index]))
                context.fill(flipped(cellRect))
                if position - Double(index) > (Double(bayer[row % 4][column % 4]) + 0.5) / 16 {
                    context.setFillColor(color(stops[index + 1]))
                    context.fill(flipped(cellRect.insetBy(dx: CGFloat(cell - dot) / 2, dy: CGFloat(cell - dot) / 2)))
                }
            }
        }
    }

    private func color(_ hex: UInt32) -> CGColor {
        let channel = { (shift: UInt32) in CGFloat(hex >> shift & 0xFF) / 255 }
        return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
}

// MARK: - Files

func writePNG(_ image: CGImage, to url: URL) {
    guard let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot create \(url.path)") }
    CGImageDestinationAddImage(file, image, nil)
    guard CGImageDestinationFinalize(file) else { fatalError("cannot write \(url.path)") }
}

/// ffmpeg takes one palette for the whole loop and stores in each frame only what changed,
/// which keeps a GIF of the board at a few hundred kilobytes where ImageIO writes megabytes.
func writeGIF(_ frames: [CGImage], to url: URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
        fatalError("cannot create \(folder.path): \(error)")
    }
    defer { try? FileManager.default.removeItem(at: folder) }
    for (index, frame) in frames.enumerated() {
        writePNG(frame, to: folder.appendingPathComponent(String(format: "%03d.png", index)))
    }
    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments = [
        "ffmpeg", "-v", "error", "-y", "-framerate", String(Int(Timeline.framesPerSecond)),
        "-i", folder.appendingPathComponent("%03d.png").path,
        "-vf", "split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle",
        "-loop", "0", url.path,
    ]
    do {
        try ffmpeg.run()
    } catch {
        fatalError("cannot run ffmpeg: \(error)")
    }
    ffmpeg.waitUntilExit()
    guard ffmpeg.terminationStatus == 0 else { fatalError("ffmpeg failed on \(url.lastPathComponent)") }
    print(url.lastPathComponent, frames.count, "frames")
}
