import AppKit
import SwiftUI

/// A drag in points from the top left corner of the board: the mouse, or two fingers on a trackpad.
struct Drag {
    var startLocation: CGPoint
    var location: CGPoint
    var translation: CGSize
    var predictedEndTranslation: CGSize
    var velocity: CGSize
    var time: Date
    /// Two fingers on a trackpad only ever scroll; a click comes separately.
    var canTap = true
}

extension Drag {
    init(_ value: DragGesture.Value) {
        self.init(
            startLocation: value.startLocation,
            location: value.location,
            translation: value.translation,
            predictedEndTranslation: value.predictedEndTranslation,
            velocity: value.velocity,
            time: value.time
        )
    }
}

enum Feedback {
    case light, medium, error

    /// Felt only while a finger rests on a Force Touch trackpad.
    func play() {
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch self {
        case .light: .alignment
        case .medium: .levelChange
        case .error: .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// Turns drags and taps into scrolling, swipes between screens, pull to refresh and presses.
@MainActor
@Observable
final class DeckGestures {
    private static let tapSlop: CGFloat = 8
    private static let axisLockDistance: CGFloat = 10
    private static let coastCheckInterval: Duration = .milliseconds(100)
    /// The velocity of a drag keeps its last value, so a finger this still lifts without a flick.
    private static let restedFingerDelay: TimeInterval = 0.1
    private static let swipeFinish = Animation.easeOut(duration: 0.18)
    /// How far the finger has to travel for each point the content moves.
    private static let pullResistance: CGFloat = 0.5
    private static let pullArmDistance: CGFloat = 60
    private static let pullRestDistance: CGFloat = 52
    private static let pullLimit: CGFloat = 100
    private static let pullSettle = Animation.easeOut(duration: 0.2)
    private static let minimumRefreshDuration: Duration = .milliseconds(800)
    private static let resultDuration: Duration = .milliseconds(800)

    private(set) var swipeOffset: CGFloat = 0
    private(set) var pullOffset: CGFloat = 0
    /// While anything moves, frames follow the display rate.
    private(set) var isMoving = false

    @ObservationIgnored private let model: DeckModel
    @ObservationIgnored private let scene: Scene
    @ObservationIgnored private var scrollAtDragStart: Double?
    @ObservationIgnored private var dragAxis: Axis?
    @ObservationIgnored private var isSwipingRow = false
    @ObservationIgnored private var lastDragChange = Date.distantPast
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var touchStoppedCoast = false
    @ObservationIgnored private var settling: Task<Void, Never>?

    init(model: DeckModel, scene: Scene) {
        self.model = model
        self.scene = scene
    }

    func changed(_ drag: Drag) {
        if scrollAtDragStart == nil {
            touchStoppedCoast = scene.feed.hold()
            settling?.cancel()
            isMoving = true
        }
        lastDragChange = drag.time
        let start = scrollAtDragStart ?? scene.feed.scroll
        scrollAtDragStart = start
        lockAxis(for: drag, scrollAtStart: start)
        if isSwipingRow {
            follow(rowDrag: drag.translation.width)
        } else if dragAxis == .horizontal {
            let direction = scene.exitDirection
            swipeOffset = direction * max(0, direction * drag.translation.width)
        } else {
            follow(verticalDrag: drag.translation.height, scrollAtStart: start)
        }
    }

    func ended(_ drag: Drag, screenWidth: CGFloat) {
        let axis = dragAxis
        let wasSwipingRow = isSwipingRow
        dragAxis = nil
        isSwipingRow = false
        scrollAtDragStart = nil
        let isTap = drag.canTap
            && abs(drag.translation.height) < Self.tapSlop
            && abs(drag.translation.width) < Self.tapSlop
        if wasSwipingRow {
            finishRowSwipe(predictedEnd: drag.predictedEndTranslation.width)
        } else if isRefreshing {
            scene.feed.release(velocity: 0)
        } else if isTap {
            scene.feed.release(velocity: 0)
            retractPull()
            if !touchStoppedCoast { tap(atX: drag.location.x, y: drag.location.y) }
        } else if axis == .horizontal {
            scene.feed.release(velocity: 0)
            finishSwipe(predictedEnd: drag.predictedEndTranslation.width, screenWidth: screenWidth)
        } else if scene.pullState == .armed {
            scene.feed.release(velocity: 0)
            beginRefresh()
        } else if pullOffset > 0 {
            scene.feed.release(velocity: 0)
            retractPull()
        } else {
            let isFlick = drag.time.timeIntervalSince(lastDragChange) < Self.restedFingerDelay
            coast(velocity: isFlick ? -drag.velocity.height / Scene.feedPixel : 0)
        }
    }

    /// A mouse wheel moves the feed in steps: no pull, no swipes, nothing to press.
    func scroll(by distance: CGFloat) {
        let feed = scene.feed
        feed.hold()
        settling?.cancel()
        isMoving = true
        feed.drag(to: max(feed.scroll - distance / Scene.feedPixel, 0))
        coast(velocity: 0)
    }

    /// Past the top of the feed the same drag turns into pull to refresh.
    private func follow(verticalDrag distance: CGFloat, scrollAtStart: Double) {
        let position = scrollAtStart - distance / Scene.feedPixel
        scene.feed.drag(to: max(position, 0))
        guard !isRefreshing, refreshSource != nil else { return }
        let overscroll = max(-position, 0) * Scene.feedPixel
        pullOffset = min(overscroll * Self.pullResistance, Self.pullLimit)
        if pullOffset == 0 {
            scene.pullState = .hidden
        } else {
            scene.pullState = pullOffset >= Self.pullArmDistance ? .armed : .pulling
        }
    }

    /// Pull to refresh asks one source, so it means nothing where that source is switched off.
    private var refreshSource: RefreshSource? {
        switch scene.screen {
        case .board, .github: model.deck.showsGithub ? .github : nil
        case .orca: model.deck.showsOrca ? .orca : nil
        case .claude, .meetings, .catalog: nil
        }
    }

    private func beginRefresh() {
        guard let source = refreshSource else { return retractPull() }
        isRefreshing = true
        scene.pullState = .refreshing
        withAnimation(Self.pullSettle) { pullOffset = Self.pullRestDistance }
        Task {
            async let isUpdated = model.refresh(source)
            try? await Task.sleep(for: Self.minimumRefreshDuration)
            scene.pullState = await isUpdated ? .succeeded : .failed
            try? await Task.sleep(for: Self.resultDuration)
            isRefreshing = false
            retractPull()
        }
    }

    private func retractPull() {
        withAnimation(Self.pullSettle, completionCriteria: .logicallyComplete) {
            pullOffset = 0
        } completion: {
            self.scene.pullState = .hidden
            self.isMoving = false
        }
    }

    private func lockAxis(for drag: Drag, scrollAtStart: Double) {
        let translation = drag.translation
        guard dragAxis == nil,
              max(abs(translation.width), abs(translation.height)) >= Self.axisLockDistance
        else { return }
        if abs(translation.width) > abs(translation.height), let chat = scene.swipeableChat(
            atX: drag.startLocation.x, y: drag.startLocation.y, dragWidth: translation.width
        ) {
            dragAxis = .horizontal
            isSwipingRow = true
            scene.feed.scroll = scrollAtStart
            scene.feed.grabRow(chat)
            return
        }
        _ = scene.feed.coverRow()
        let isHorizontal = scene.exitDirection * translation.width > abs(translation.height)
        dragAxis = isHorizontal ? .horizontal : .vertical
        if isHorizontal {
            scene.feed.scroll = scrollAtStart
            scene.isRevealingExit = true
        }
    }

    private func follow(rowDrag distance: CGFloat) {
        let feed = scene.feed
        let wasPastCloseLine = feed.isRowPastCloseLine
        feed.dragRow(by: distance / Scene.feedPixel)
        if feed.isRowPastCloseLine != wasPastCloseLine, let chat = feed.swipedRow?.key, closesBySwipe(chat) {
            Feedback.medium.play()
        }
    }

    private func finishRowSwipe(predictedEnd: CGFloat) {
        let feed = scene.feed
        if feed.isRowPastCloseLine, let chat = feed.swipedRow?.key, closesBySwipe(chat) {
            close(chat: chat)
        } else {
            feed.settleRow(heading: predictedEnd / Scene.feedPixel)
        }
        coast(velocity: 0)
    }

    /// A finished chat goes with one long swipe; stopping an agent at work takes a tap on the button.
    private func closesBySwipe(_ chat: String) -> Bool {
        model.deck.orca.first { $0.id == chat }?.isAtWork == false
    }

    private func close(chat: String) {
        Feedback.medium.play()
        scene.feed.dropRow()
        scene.closingChats.insert(chat)
        Task {
            let isClosed = await model.closeChat(key: chat)
            scene.closingChats.remove(chat)
            if !isClosed { Feedback.error.play() }
        }
    }

    private func finishSwipe(predictedEnd: CGFloat, screenWidth: CGFloat) {
        let direction = scene.exitDirection
        let leaves = direction * predictedEnd > screenWidth / 2
        withAnimation(Self.swipeFinish, completionCriteria: .logicallyComplete) {
            swipeOffset = leaves ? direction * screenWidth : 0
        } completion: {
            if leaves { self.scene.leave() }
            self.swipeOffset = 0
            self.scene.isRevealingExit = false
            self.isMoving = false
        }
    }

    private func coast(velocity: Double) {
        scene.feed.release(velocity: velocity)
        settling = Task {
            while scene.feed.isCoasting, !Task.isCancelled {
                try? await Task.sleep(for: Self.coastCheckInterval)
            }
            if !Task.isCancelled { isMoving = false }
        }
    }

    private func tap(atX x: CGFloat, y: CGFloat) {
        let target = scene.target(atX: x, y: y)
        if case .closeChat(let chat) = target { return close(chat: chat) }
        // A tap beside an uncovered button only covers it again, as in Messages.
        if scene.feed.coverRow() { return coast(velocity: 0) }
        switch target {
        case .action(let card, let index): model.press(card: card, actionIndex: index)
        case .dismiss(let card): model.dismiss(card: card)
        case .mute(let card): model.mute(pullRequest: card)
        case .openOnMac(let card):
            Feedback.light.play()
            model.openOnMac(pullRequest: card)
        case .openChat(let key):
            Feedback.light.play()
            model.openChat(key: key)
        case .openLink(let url):
            Feedback.light.play()
            NSWorkspace.shared.open(url)
        case .openOrca: scene.show(.orca)
        case .openClaude: scene.show(.claude)
        case .openGithub: scene.show(.github)
        case .openMeetings: scene.show(.meetings)
        case .back: scene.show(.board)
        case .toggle(let integration):
            Feedback.light.play()
            model.toggle(integration)
        case .closeChat, nil: break
        }
    }
}
