import Foundation

/// Where a notification comes from. Cards are not among them: a card stays on the board by itself.
enum NewsSource: String, Codable {
    case orca, claude, github, meetings

    /// The title of its tile.
    var title: String { rawValue.uppercased() }

    /// Settings stores the choice under this key, and the notch reads it for every notification.
    var modeKey: String { "news.\(rawValue)" }

    var mode: NewsMode {
        UserDefaults.standard.string(forKey: modeKey).flatMap(NewsMode.init) ?? .standard
    }
}

/// What a notification does: nothing, a line under the closed notch, or the line and then a row on the board.
enum NewsMode: String {
    case off, shown, kept

    static let standard = NewsMode.shown
}

/// The notifications of sources set to `kept`, newest first. They stay on the board until cleared there.
@MainActor
final class NewsHistory {
    enum Link: Codable {
        case url(URL)
        case chat(key: String)
    }

    struct Entry: Codable {
        var id: String
        var source: NewsSource
        var light: Light?
        var text: String
        var link: Link?
        var date: Date
    }

    private static let defaultsKey = "keptNews"
    private static let limit = 50

    private(set) var entries: [Entry]

    init() {
        entries = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func keep(source: NewsSource, light: Light?, text: String, link: Link?, at date: Date) {
        let entry = Entry(id: UUID().uuidString, source: source, light: light, text: text, link: link, date: date)
        entries = Array(([entry] + entries).prefix(Self.limit))
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.defaultsKey)
    }
}
