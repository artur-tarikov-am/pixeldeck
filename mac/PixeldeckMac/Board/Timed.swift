import Foundation

/// An act of a skit: it lasts a while, then gives way to the next one.
protocol Timed {
    var seconds: TimeInterval { get }
}

extension Array where Element: Timed {
    var duration: TimeInterval {
        reduce(0) { $0 + $1.seconds }
    }

    /// The act on stage `elapsed` seconds in, and how long it has been on; nil once all of them are over.
    func act(at elapsed: TimeInterval) -> (act: Element, elapsed: TimeInterval)? {
        var elapsed = elapsed
        for act in self {
            if elapsed < act.seconds { return (act, elapsed) }
            elapsed -= act.seconds
        }
        return nil
    }
}
