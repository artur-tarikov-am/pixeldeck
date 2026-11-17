import Foundation

/// The character stays on the wing while the closed notch has something new to show. Once the wings
/// have shown the same for the time chosen in Settings, or have nothing left to show, it walks into the notch
/// and the wings fold behind it. As soon as what they show changes, or someone has looked at the board, it walks back out.
@MainActor
final class CharacterPresence {
    /// What the wings tell about the board; any change of it brings the character back.
    struct Look: Equatable {
        var mood: String
        /// Agents in each state, whatever order their rows come in.
        var counts: [Light: Int]
    }

    /// Minutes the wings may show the same before the character leaves, chosen in Settings; 0 keeps it on the wing.
    static let minutesKey = "characterLeavesAfterMinutes"
    static let defaultMinutes = 3
    /// From its place on the wing until it is out of sight in the notch.
    private static let walkTime: TimeInterval = 1.5

    private var look: Look?
    /// When the wings last changed or something happened on them.
    private var activeAt = Date.distantPast
    /// The notch starts out with nothing on its wings.
    private var quietSince: Date? = .distantPast
    /// When the character last turned back to the wing, and how far along the walk it was then.
    private var turnedBack = (at: Date.distantPast, distance: 1.0)

    /// Hears what the wings show at this moment, nil while there is nothing. While `isEventful`, such as
    /// with a line of news under the notch or a meeting about to start, the character stays though the look holds still.
    func see(_ look: Look?, isEventful: Bool, at now: Date) {
        if look == nil {
            quietSince = quietSince ?? now
        } else if look != self.look || isEventful {
            callBack(at: now)
            quietSince = nil
        }
        self.look = look
    }

    /// Brings the character back to the wing and starts its wait over. With nothing on the wings it stays in the notch.
    func callBack(at now: Date) {
        turnedBack = (now, distance(at: now))
        activeAt = now
    }

    /// How far along its walk into the notch the character is: 0 on its place on the wing, 1 out of sight.
    func distance(at now: Date) -> Double {
        let departure = departure
        let back = turnedBack.distance - Self.walked(from: turnedBack.at, to: min(now, departure))
        return min(1, max(0, back) + Self.walked(from: departure, to: now))
    }

    /// When the character starts, or started, walking into the notch. Read each time, so a new choice
    /// in Settings applies at once.
    private var departure: Date {
        let minutes = UserDefaults.standard.object(forKey: Self.minutesKey) as? Int ?? Self.defaultMinutes
        let bored = minutes > 0 ? activeAt.addingTimeInterval(TimeInterval(minutes * 60)) : .distantFuture
        return min(quietSince ?? .distantFuture, bored)
    }

    private static func walked(from start: Date, to end: Date) -> Double {
        max(0, end.timeIntervalSince(start)) / walkTime
    }
}
