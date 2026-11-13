import Foundation

/// What just happened on the board, told one at a time in a line under the closed notch,
/// so it does not pass by while nobody looks at the wings. News are the cards that arrive,
/// the agents and pull requests whose light turns to something worth a glance,
/// and the meetings five minutes before they start and as they start.
@MainActor
final class NotchNews {
    struct Item {
        /// The row the news is about: newer news about it replaces the older one still waiting.
        var key: String
        var light: Light?
        var name: String
        /// What happened to it; a card says everything in its title.
        var change: String?
    }

    private struct Row {
        var key: String
        var light: Light
        var name: String
    }

    private struct Reminder: Hashable {
        var meeting: String
        var lead: TimeInterval
    }

    private static let shownFor: TimeInterval = 3
    /// How long before the start a meeting reminds of itself, and what it says then.
    private static let reminders: [(lead: TimeInterval, says: String)] = [(5 * 60, "in 5m"), (0, "starts now")]
    /// A reminder missed by longer, such as while the notch was open, is not worth telling late.
    private static let reminderGrace: TimeInterval = 60

    private var queue: [Item] = []
    private var shownSince: Date?
    private var toldReminders: Set<Reminder> = []

    func hear(old: Deck, new: Deck) {
        Self.news(from: old, to: new).forEach(tell)
    }

    func hear(_ meetings: [Meeting], at now: Date) {
        toldReminders = toldReminders.filter { told in meetings.contains { $0.key == told.meeting } }
        for meeting in meetings {
            for reminder in Self.reminders {
                let due = meeting.start.addingTimeInterval(-reminder.lead)
                let told = Reminder(meeting: meeting.key, lead: reminder.lead)
                guard now >= due, now.timeIntervalSince(due) < Self.reminderGrace, !toldReminders.contains(told)
                else { continue }
                toldReminders.insert(told)
                tell(Item(key: meeting.key, light: meeting.phase(at: now)?.light, name: meeting.title, change: reminder.says))
            }
        }
    }

    private func tell(_ item: Item) {
        if queue.first?.key == item.key { shownSince = nil }
        queue.removeAll { $0.key == item.key }
        queue.append(item)
    }

    func clear() {
        queue = []
        shownSince = nil
    }

    /// The news to show at this moment; each one stays for `shownFor`, in the order they came.
    func current(at now: Date) -> Item? {
        if let shownSince, now.timeIntervalSince(shownSince) >= Self.shownFor {
            queue.removeFirst()
            self.shownSince = nil
        }
        guard let item = queue.first else { return nil }
        if shownSince == nil { shownSince = now }
        return item
    }

    private static func news(from old: Deck, to new: Deck) -> [Item] {
        let known = Set(old.cards.map(\.id))
        var news = new.cards.filter { !known.contains($0.id) }.map {
            Item(key: $0.id, light: $0.light, name: $0.title)
        }
        if new.showsOrca {
            news += changes(
                from: old.orca.map { Row(key: $0.id, light: $0.light, name: $0.title) },
                to: new.orca.map { Row(key: $0.id, light: $0.light, name: $0.title) },
                says: agentChange
            )
        }
        if new.showsClaude {
            news += changes(
                from: old.claude.map { Row(key: $0.id, light: $0.light, name: $0.project) },
                to: new.claude.map { Row(key: $0.id, light: $0.light, name: $0.project) },
                says: agentChange
            )
        }
        if new.showsGithub {
            news += changes(
                from: old.github.map { Row(key: $0.key, light: $0.light, name: $0.title) },
                to: new.github.map { Row(key: $0.key, light: $0.light, name: $0.title) },
                says: pullRequestChange
            )
        }
        return news
    }

    /// Only rows that were there before: a row that just appeared, such as every chat
    /// after the hub starts, has no change to tell.
    private static func changes(from old: [Row], to new: [Row], says change: (Light) -> String?) -> [Item] {
        let before = Dictionary(old.map { ($0.key, $0.light) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { row in
            guard let light = before[row.key], light != row.light, let change = change(row.light) else { return nil }
            return Item(key: row.key, light: row.light, name: row.name, change: change)
        }
    }

    private static func agentChange(_ light: Light) -> String? {
        switch light {
        case .waiting: "waits for you"
        case .done: "finished"
        case .failed: "failed"
        case .running, .idle, .review: nil
        }
    }

    /// Review requests always have the same light, so only pull requests of the user change.
    private static func pullRequestChange(_ light: Light) -> String? {
        switch light {
        case .done: "approved"
        case .failed: "CI failed"
        case .waiting: "changes requested"
        case .running, .idle, .review: nil
        }
    }
}
