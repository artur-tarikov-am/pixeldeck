import Foundation

/// A meeting from the calendar of the Mac.
struct Meeting: Equatable {
    enum Phase {
        /// More than ten minutes away.
        case later
        case soon
        /// From two minutes before the start until five minutes into it: time to join.
        case starting
        case underway

        var light: Light {
            switch self {
            case .later: .idle
            case .soon: .review
            case .starting: .waiting
            case .underway: .running
            }
        }
    }

    private static let soonLead: TimeInterval = 10 * 60
    private static let startingLead: TimeInterval = 2 * 60
    private static let joiningTime: TimeInterval = 5 * 60

    var key: String
    var title: String
    var start: Date
    var end: Date
    /// The call, when the event has one.
    var link: URL?

    /// Nil once it is over.
    func phase(at now: Date) -> Phase? {
        guard now < end else { return nil }
        let untilStart = start.timeIntervalSince(now)
        if untilStart > Self.soonLead { return .later }
        if untilStart > Self.startingLead { return .soon }
        return -untilStart < Self.joiningTime ? .starting : .underway
    }

    func minutesUntilStart(at now: Date) -> Int {
        Self.minutes(start.timeIntervalSince(now))
    }

    func minutesLeft(at now: Date) -> Int {
        Self.minutes(end.timeIntervalSince(now))
    }

    private static func minutes(_ interval: TimeInterval) -> Int {
        Int((interval / 60).rounded(.up))
    }
}
