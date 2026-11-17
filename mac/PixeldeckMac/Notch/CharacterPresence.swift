import Foundation

/// The character stays on the wing while the closed notch has something new to show. Once the wings
/// have shown the same for the time chosen in Settings, or have nothing left to show, it leaves in one of its skits.
/// As soon as what they show changes, or someone has looked at the board, it comes back in another.
@MainActor
final class CharacterPresence {
    /// What the wings tell about the board; any change of it brings the character back.
    struct Look: Equatable {
        var mood: String
        /// Agents in each state, whatever order their rows come in.
        var counts: [Light: Int]
    }

    enum Stage {
        case onWing
        case playing(Skit, elapsed: TimeInterval)
        /// Out of sight for `elapsed` seconds.
        case away(elapsed: TimeInterval)
    }

    private enum Turn {
        /// Plays the skit, then stays on the wing.
        case arriving(Skit, at: Date)
        case leaving(Skit, at: Date)
        case away(since: Date)
    }

    /// Seconds the wings may show the same before the character leaves, chosen in Settings; 0 keeps it on the wing.
    static let secondsKey = "characterLeavesAfterSeconds"
    static let defaultSeconds = 180

    private var look: Look?
    /// When the wings last changed or something happened on them.
    private var activeAt = Date.distantPast
    /// The notch starts out with nothing on its wings.
    private var quietSince: Date? = .distantPast
    private var turn = Turn.away(since: .distantPast)
    private var arrivals = Shuffled(Skit.arrivals)
    private var departures = Shuffled(Skit.departures)

    /// Hears what the wings show at this moment, nil while there is nothing. While `isEventful`, such as
    /// with a line of news under the notch or a meeting about to start, the character stays though the look holds still.
    func see(_ look: Look?, isEventful: Bool, at now: Date) {
        if look == nil {
            quietSince = quietSince ?? now
        } else if look != self.look || isEventful {
            quietSince = nil
            callBack(at: now)
        }
        self.look = look
    }

    /// Brings the character back to the wing and starts its wait over. With nothing on the wings it stays in the notch.
    func callBack(at now: Date) {
        activeAt = now
        guard quietSince == nil else { return }
        advance(to: now)
        switch turn {
        case .away:
            turn = .arriving(arrivals.next(), at: now)
        case let .leaving(skit, start):
            turn = .arriving(.startled(from: skit.spot(at: now.timeIntervalSince(start))), at: now)
        case .arriving:
            break
        }
    }

    func stage(at now: Date) -> Stage {
        advance(to: now)
        switch turn {
        case let .away(since):
            return .away(elapsed: now.timeIntervalSince(since))
        case let .leaving(skit, start):
            return .playing(skit, elapsed: now.timeIntervalSince(start))
        case let .arriving(skit, start):
            let elapsed = now.timeIntervalSince(start)
            return elapsed < skit.duration ? .playing(skit, elapsed: elapsed) : .onWing
        }
    }

    /// Sends the character off once its wait is over, and counts it away once its skit has taken it out of sight.
    private func advance(to now: Date) {
        if case let .arriving(skit, start) = turn {
            let leaving = max(departure, start.addingTimeInterval(skit.duration))
            if now >= leaving { turn = .leaving(departures.next(), at: leaving) }
        }
        if case let .leaving(skit, start) = turn {
            let gone = start.addingTimeInterval(skit.duration)
            if now >= gone { turn = .away(since: gone) }
        }
    }

    /// When the character is due to leave. Read each time, so a new choice in Settings applies at once.
    private var departure: Date {
        let seconds = UserDefaults.standard.object(forKey: Self.secondsKey) as? Int ?? Self.defaultSeconds
        let bored = seconds > 0 ? activeAt.addingTimeInterval(TimeInterval(seconds)) : .distantFuture
        return min(quietSince ?? .distantFuture, bored)
    }
}

/// Hands out every skit once, in random order, before any comes round again.
private struct Shuffled {
    private let skits: [Skit]
    private var left: [Skit] = []

    init(_ skits: [Skit]) {
        self.skits = skits
    }

    mutating func next() -> Skit {
        if left.isEmpty { left = skits.shuffled() }
        return left.removeLast()
    }
}
