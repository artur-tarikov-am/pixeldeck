import Foundation

struct Deck: Decodable {
    var cards: [Card]
    var status: Status
    var orca: [OrcaSession]
    var claude: [ClaudeSession]
    var github: [GithubItem]
    var integrations: [Integration]

    static let empty = Deck(
        cards: [],
        status: Status(mood: "idle", text: nil),
        orca: [],
        claude: [],
        github: [],
        integrations: []
    )

    var showsOrca: Bool { shows("orca") }
    /// Next to Orca this tile only takes room while there are sessions outside it.
    var showsClaude: Bool { shows("claude") && (!showsOrca || !claude.isEmpty) }
    var showsGithub: Bool { shows("github") }
    var isBlank: Bool { !showsOrca && !showsClaude && !showsGithub && cards.isEmpty }
    /// The cards that are not notifications.
    var plainCards: [Card] { cards.filter { !$0.isNotification } }

    func without(_ rows: Set<String>) -> Deck {
        var deck = self
        deck.cards.removeAll { rows.contains($0.id) }
        deck.orca.removeAll { rows.contains($0.id) }
        deck.github.removeAll { rows.contains($0.key) }
        return deck
    }

    /// Until the hub answers nothing is known, and the tiles are what shows the connection.
    private func shows(_ id: String) -> Bool {
        integrations.first { $0.id == id }?.isOn ?? true
    }
}

struct Integration: Decodable {
    var id: String
    var title: String
    var text: String
    var isOn: Bool
}

struct Status: Decodable {
    var mood: String
    var text: String?
}

struct OrcaSession: Decodable {
    var id: String
    var provider: String
    var project: String
    var title: String
    var light: Light
    var question: String?
    /// At work or finished within the last couple of minutes; older chats only stay in the list.
    var isCurrent: Bool
    var isPinned: Bool

    var isAtWork: Bool { light == .running || light == .waiting }

    var card: Card {
        Card(id: id, title: title, text: question ?? "\(provider) · \(project)", light: light, actions: [])
    }
}

struct ClaudeSession: Decodable {
    var id: String
    var project: String
    var light: Light
    var question: String?

    var card: Card {
        Card(id: id, title: project, text: question, light: light, actions: [])
    }
}

struct GithubItem: Decodable {
    enum Group: String, Decodable {
        case mine, review, mention
    }

    var key: String
    var group: Group
    var light: Light
    var title: String
    var text: String
    /// Kept as text, so a link the app cannot read does not break the whole stream.
    var url: String?
    /// Who approved a pull request of the user, nil when the hub does not know.
    var approvedBy: [String]?

    var card: Card {
        Card(id: key, title: title, text: text, light: light, actions: [])
    }
}

struct Card: Decodable, Identifiable {
    /// How the feed draws the row.
    enum Look {
        case card
        /// A kept notification, with the tile it came from and when.
        case news(source: String, when: String)
        /// The label over the kept notifications.
        case heading
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, title, text, note, sprite, light, actions, createdAt
    }

    /// The hub writes the time in UTC without saying so.
    private static let hubTime = Date.ISO8601FormatStyle().year().month().day().time(includingFractionalSeconds: true)

    var id: String
    /// Set by the script or agent that sent the card as a notification.
    var source: String?
    var title: String
    var text: String?
    var note: String?
    var sprite: SpriteReference?
    var light: Light?
    var actions: [CardAction]
    var createdAt: String?
    var look = Look.card

    var isNotification: Bool { source != nil }

    var createdDate: Date? {
        createdAt.flatMap { try? Date($0, strategy: Self.hubTime) }
    }
}

struct CardAction: Decodable {
    enum State: String, Decodable {
        case idle, running, done, failed
    }

    var label: String
    var url: URL?
    var state: State
}

enum SpriteReference: Decodable {
    case named(String)
    case inline(Sprite)

    private struct InlineSprite: Decodable {
        let palette: [String: String]
        let frames: [[String]]
        let fps: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .named(name)
        } else {
            let sprite = try container.decode(InlineSprite.self)
            self = .inline(Sprite(palette: sprite.palette, frames: sprite.frames, fps: sprite.fps))
        }
    }

    var sprite: Sprite? {
        switch self {
        case .named(let name): SpriteLibrary.named(name)
        case .inline(let sprite): sprite
        }
    }

    var name: String? {
        if case .named(let name) = self { name } else { nil }
    }
}
