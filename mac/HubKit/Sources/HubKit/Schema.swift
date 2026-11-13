import Foundation

public enum Mood: String, Codable, Sendable {
    case idle, thinking, waiting, done, error
}

public enum ActionState: String, Codable, Sendable {
    case idle, running, done, failed
}

public enum Light: String, Codable, Sendable {
    case running, waiting, done, failed, idle, review

    /// How long a finished chat or session still counts as activity.
    static let finishedVisible: TimeInterval = 2 * 60
    /// What needs attention goes first.
    private static let attentionOrder: [Set<Light>] = [[.waiting], [.running], [.failed], [.done, .idle, .review]]

    var isFinished: Bool { self == .done || self == .failed }

    static func byAttention<Row>(_ rows: [Row], light: (Row) -> Light) -> [Row] {
        attentionOrder.flatMap { group in rows.filter { group.contains(light($0)) } }
    }
}

public struct InlineSprite: Codable, Sendable, Equatable {
    static let maxSide = 32

    var palette: [String: String]
    var frames: [[String]]
    var fps: Double
}

public enum SpriteReference: Codable, Sendable, Equatable {
    case named(String)
    case inline(InlineSprite)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .named(name)
        } else {
            self = .inline(try container.decode(InlineSprite.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .named(let name): try container.encode(name)
        case .inline(let sprite): try container.encode(sprite)
        }
    }
}

public struct CardAction: Codable, Sendable, Equatable {
    public var label: String
    public var url: String?
    public var run: String?
    public var args: [String]?
    public var reply: String?
    public var state: ActionState
}

public struct Card: Codable, Sendable, Equatable {
    public var id: String
    public var key: String?
    public var title: String
    public var text: String?
    public var sprite: SpriteReference?
    public var createdAt: String
    public var note: String?
    public var actions: [CardAction]
}

public struct Status: Codable, Sendable, Equatable {
    public var mood: Mood
    public var text: String?

    static let idle = Status(mood: .idle)
}

public struct ClaudeSession: Codable, Sendable, Equatable {
    public var id: String
    public var project: String
    public var light: Light
    public var startedAt: Int64
    public var question: String?
}

public struct OrcaSession: Codable, Sendable, Equatable {
    public var id: String
    public var provider: String
    public var project: String
    public var title: String
    public var light: Light
    public var question: String?
    /// Orca remembers finished chats for days; those stay in the list but no longer count for the mood.
    public var isCurrent: Bool
    public var isPinned: Bool
}

public struct GithubItem: Codable, Sendable, Equatable {
    public enum Group: String, Codable, Sendable {
        case mine, review
    }

    public var key: String
    public var group: Group
    public var light: Light
    public var title: String
    public var text: String
    public var url: String
}

public enum IntegrationID: String, Codable, Sendable {
    case orca, claude, github

    /// Whether this Mac has what the integration reads: Orca has run here, `gh` has a login.
    public static let isSetUpOnThisMac: IsSetUp = { id in
        switch id {
        case .orca: OrcaRuntime.hasRun
        case .claude: true
        case .github: GithubCommands.hasLogin
        }
    }
}

public typealias IsSetUp = @Sendable (IntegrationID) -> Bool

public struct Integration: Codable, Sendable, Equatable {
    public var id: IntegrationID
    public var title: String
    public var text: String
    public var isOn: Bool

    static let catalog = [
        Integration(id: .orca, title: "ORCA", text: "chats and agent terminals in Orca, of any provider", isOn: true),
        Integration(id: .claude, title: "CLAUDE", text: "Claude Code sessions outside Orca", isOn: true),
        Integration(id: .github, title: "GITHUB", text: "your pull requests and review requests", isOn: true),
    ]

    /// A new board shows only what this Mac can feed.
    static func defaults(isSetUp: IsSetUp) -> [Integration] {
        catalog.map { entry in
            var entry = entry
            entry.isOn = isSetUp(entry.id)
            return entry
        }
    }
}

public struct DeckState: Codable, Sendable, Equatable {
    public var cards: [Card] = []
    public var status = Status.idle
    public var orca: [OrcaSession] = []
    public var claude: [ClaudeSession] = []
    public var github: [GithubItem] = []
    public var integrations = Integration.catalog
}
