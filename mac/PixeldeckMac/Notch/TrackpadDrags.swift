import AppKit

/// Two fingers on a trackpad drag the board the way the mouse does:
/// scrolling, pull to refresh, swipes between screens and the close button under a chat.
/// A mouse wheel only scrolls.
@MainActor
final class TrackpadDrags {
    private static let wheelStep: CGFloat = 16
    /// The speed of a flick comes from the last moments before the fingers lift.
    private static let flickWindow: TimeInterval = 0.08
    /// Where a flick would carry the content, as SwiftUI predicts for a finger.
    private static let predictionTime: CGFloat = 0.25

    private var drag: Drag?
    private var recent: [(time: TimeInterval, delta: CGSize)] = []

    /// `point` is in board coordinates.
    func handle(_ event: NSEvent, at point: CGPoint, gestures: DeckGestures, boardWidth: CGFloat) {
        guard event.hasPreciseScrollingDeltas else {
            return gestures.scroll(by: event.scrollingDeltaY * Self.wheelStep)
        }
        // The feed coasts on its own, so the momentum macOS adds is dropped.
        guard event.momentumPhase.isEmpty else { return }
        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        switch event.phase {
        case .began:
            recent = []
            drag = Drag(
                startLocation: point, location: point, translation: .zero,
                predictedEndTranslation: .zero, velocity: .zero, time: .now, canTap: false
            )
            follow(delta, at: event.timestamp, gestures: gestures)
        case .changed:
            follow(delta, at: event.timestamp, gestures: gestures)
        case .ended, .cancelled:
            guard var drag else { return }
            let velocity = flickVelocity(at: event.timestamp)
            drag.velocity = velocity
            drag.predictedEndTranslation = CGSize(
                width: drag.translation.width + velocity.width * Self.predictionTime,
                height: drag.translation.height + velocity.height * Self.predictionTime
            )
            drag.time = .now
            self.drag = nil
            gestures.ended(drag, screenWidth: boardWidth)
        default:
            break
        }
    }

    private func follow(_ delta: CGSize, at timestamp: TimeInterval, gestures: DeckGestures) {
        guard var drag else { return }
        drag.translation.width += delta.width
        drag.translation.height += delta.height
        drag.time = .now
        self.drag = drag
        recent.append((timestamp, delta))
        recent.removeAll { timestamp - $0.time > Self.flickWindow }
        gestures.changed(drag)
    }

    private func flickVelocity(at timestamp: TimeInterval) -> CGSize {
        let moves = recent.filter { timestamp - $0.time <= Self.flickWindow }
        guard let first = moves.first, moves.count > 1 else { return .zero }
        let span = max(timestamp - first.time, 1.0 / 120)
        return CGSize(
            width: moves.reduce(0) { $0 + $1.delta.width } / span,
            height: moves.reduce(0) { $0 + $1.delta.height } / span
        )
    }
}
