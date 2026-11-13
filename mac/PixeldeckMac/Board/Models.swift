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
        case mine, review
    }

    var key: String
    var group: Group
    var light: Light
    var title: String
    var text: String

    var card: Card {
        Card(id: key, title: title, text: text, light: light, actions: [])
    }
}

struct Card: Decodable, Identifiable {
    var id: String
    var title: String
    var text: String?
    var note: String?
    var sprite: SpriteReference?
    var light: Light?
    var actions: [CardAction]
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
