import Foundation

/// The character stays on the wing while the closed notch has something new to show. Once the wings
/// have shown the same for a few minutes, or have nothing left to show, it walks into the notch
/// and the wings fold behind it. As soon as what they show changes, it walks back out.
@MainActor
final class CharacterPresence {
    /// What the wings tell about the board; any change of it brings the character back.
    struct Look: Equatable {
        var mood: String
        /// Agents in each state, whatever order their rows come in.
        var counts: [Light: Int]
    }

    private static let stayFor: TimeInterval = 3 * 60
    /// From its place on the wing until it is out of sight in the notch.
    private static let walkTime: TimeInterval = 1.5

    private var look: Look?
    /// When the character starts, or started, walking into the notch.
    private var departure = Date.distantPast
    /// When it last turned back to the wing, and how far along the walk it was then.
    private var turnedBack = (at: Date.distantPast, distance: 1.0)

    /// Hears what the wings show at this moment, nil while there is nothing. While `isEventful`, such as
    /// with a line of news under the notch or a meeting about to start, the character stays though the look holds still.
    func see(_ look: Look?, isEventful: Bool, at now: Date) {
        if look == nil {
            departure = min(departure, now)
        } else if look != self.look || isEventful {
            turnedBack = (now, distance(at: now))
            departure = now.addingTimeInterval(Self.stayFor)
        }
        self.look = look
    }

    /// How far along its walk into the notch the character is: 0 on its place on the wing, 1 out of sight.
    func distance(at now: Date) -> Double {
        let back = turnedBack.distance - Self.walked(from: turnedBack.at, to: min(now, departure))
        return min(1, max(0, back) + Self.walked(from: departure, to: now))
    }

    private static func walked(from start: Date, to end: Date) -> Double {
        max(0, end.timeIntervalSince(start)) / walkTime
    }
}
