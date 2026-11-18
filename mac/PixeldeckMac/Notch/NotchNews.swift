import Foundation

/// What just happened on the board, told one at a time in a line under the closed notch,
/// so it does not pass by while nobody looks at the wings. News are the cards and GitHub mentions
/// that arrive, approvals of the user's pull requests, the agents and pull requests whose light turns
/// to something worth a glance, and the meetings five minutes before they start and as they start.
/// Settings can switch the news of a source off, or keep it on the board in `NewsHistory`.
@MainActor
final class NotchNews {
    struct Item {
        /// The row the news is about: newer news about it replaces the older one still waiting.
        var key: String
        /// Nil for a card, which stays on the board by itself.
        var source: NewsSource?
        var light: Light?
        var name: String
        /// What happened to it; a card says everything in its title.
        var change: String?
        /// Where the news leads once kept on the board.
        var link: NewsHistory.Link?

        var sentence: String {
            [name, change].compactMap { $0 }.joined(separator: " ")
        }
    }

    private struct Row {
        var key: String
        var light: Light
        var name: String
        var link: NewsHistory.Link?
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

    private let history: NewsHistory
    private var queue: [Item] = []
    private var shownSince: Date?
    private var toldReminders: Set<Reminder> = []

    init(history: NewsHistory) {
        self.history = history
    }

    /// The open board shows the change itself, so then the news only goes to the history.
    func hear(old: Deck, new: Deck, isOpen: Bool) {
        for item in Self.news(from: old, to: new) {
            deliver(item, tells: !isOpen, at: .now)
        }
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
                let item = Item(
                    key: meeting.key, source: .meetings, light: meeting.phase(at: now)?.light, name: meeting.title,
                    change: reminder.says, link: meeting.link.map(NewsHistory.Link.url)
                )
                deliver(item, tells: true, at: now)
            }
        }
    }

    private func deliver(_ item: Item, tells: Bool, at now: Date) {
        if let source = item.source {
            switch source.mode {
            case .off: return
            case .shown: break
            case .kept: history.keep(source: source, light: item.light, text: item.sentence, link: item.link, at: now)
            }
        }
        if tells { tell(item) }
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
            let row = { (chat: OrcaSession) in
                Row(key: chat.id, light: chat.light, name: chat.title, link: .chat(key: chat.id))
            }
            news += changes(from: old.orca.map(row), to: new.orca.map(row), source: .orca, says: agentChange)
        }
        if new.showsClaude {
            let row = { (session: ClaudeSession) in Row(key: session.id, light: session.light, name: session.project) }
            news += changes(from: old.claude.map(row), to: new.claude.map(row), source: .claude, says: agentChange)
        }
        if new.showsGithub {
            let knownGithub = Set(old.github.map(\.key))
            news += new.github.filter { $0.group == .mention && !knownGithub.contains($0.key) }.map {
                Item(key: $0.key, source: .github, light: $0.light, name: $0.text, link: $0.link)
            }
            let row = { (item: GithubItem) in Row(key: item.key, light: item.light, name: item.title, link: item.link) }
            news += changes(from: old.github.map(row), to: new.github.map(row), source: .github, says: pullRequestChange)
            news += approvals(from: old.github, to: new.github)
        }
        return news
    }

    /// Comes after the changes of light: when an approval also turns the pull request green,
    /// the line names who approved it.
    private static func approvals(from old: [GithubItem], to new: [GithubItem]) -> [Item] {
        let before = Dictionary(
            old.compactMap { row in row.approvedBy.map { (row.key, Set($0)) } },
            uniquingKeysWith: { first, _ in first }
        )
        return new.compactMap { row in
            guard let approvedBefore = before[row.key],
                  let newcomers = row.approvedBy?.filter({ !approvedBefore.contains($0) }), !newcomers.isEmpty
            else { return nil }
            return Item(
                key: row.key, source: .github, light: .done, name: row.title,
                change: "approved by \(newcomers.joined(separator: ", "))", link: row.link
            )
        }
    }

    /// Only rows that were there before: a row that just appeared, such as every chat
    /// after the hub starts, has no change to tell.
    private static func changes(
        from old: [Row],
        to new: [Row],
        source: NewsSource,
        says change: (Light) -> String?
    ) -> [Item] {
        let before = Dictionary(old.map { ($0.key, $0.light) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { row in
            guard let light = before[row.key], light != row.light, let change = change(row.light) else { return nil }
            return Item(key: row.key, source: source, light: row.light, name: row.name, change: change, link: row.link)
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

    /// Review requests and mentions always have the same light, so only pull requests of the user change.
    private static func pullRequestChange(_ light: Light) -> String? {
        switch light {
        case .done: "ready to merge"
        case .failed: "CI failed"
        case .waiting: "changes requested"
        case .running, .idle, .review: nil
        }
    }
}

private extension GithubItem {
    var link: NewsHistory.Link? {
        url.flatMap(URL.init(string:)).map(NewsHistory.Link.url)
    }
}
