import Foundation

public struct ValidationError: Error, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension Decoder {
    func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(besides _: Keys.Type) throws {
        let known = Set(Keys.allCases.map(\.stringValue))
        let unknown = try container(keyedBy: AnyKey.self).allKeys.filter { !known.contains($0.stringValue) }
        if let key = unknown.first { throw ValidationError("unknown field \(key.stringValue)") }
    }
}

func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw ValidationError(message()) }
}

/// Limits count UTF-16 units, the way the previous hub did and the way the board lays out text.
func requireLength(_ value: String, _ name: String, _ range: ClosedRange<Int>) throws {
    try require(range.contains(value.utf16.count), "\(name) must be \(range.lowerBound)-\(range.upperBound) characters long")
}

private let unlimited = Int.max

struct ActionInput: Decodable {
    let label: String
    let url: String?
    let run: String?
    let args: [String]?
    let reply: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case label, url, run, args, reply
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        run = try container.decodeIfPresent(String.self, forKey: .run)
        args = try container.decodeIfPresent([String].self, forKey: .args)
        reply = try container.decodeIfPresent(String.self, forKey: .reply)

        try requireLength(label, "label", 1...20)
        try require([url, run, reply].compactMap(\.self).count == 1, "an action needs exactly one of url, run, reply")
        try require(args == nil || run != nil, "args belong to a run action")
        if let url {
            try require(URL(string: url)?.scheme != nil, "url is not a valid URL")
        }
        if let run { try requireLength(run, "run", 1...unlimited) }
        if let reply { try requireLength(reply, "reply", 1...unlimited) }
    }

    init(option: String) {
        label = option
        reply = option
        url = nil
        run = nil
        args = nil
    }
}

private struct SpriteInput: Decodable {
    let palette: [String: String]
    let frames: [[String]]
    let fps: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case palette, frames, fps
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        palette = try container.decode([String: String].self, forKey: .palette)
        frames = try container.decode([[String]].self, forKey: .frames)
        fps = try container.decodeIfPresent(Double.self, forKey: .fps) ?? 4

        try require(fps > 0 && fps <= 30, "fps must be above 0 and at most 30")
        try require(palette.keys.allSatisfy { $0.utf16.count == 1 }, "palette keys must be one character")
        try require(
            palette.values.allSatisfy { $0.wholeMatch(of: /#[0-9a-fA-F]{6}/) != nil },
            "palette colors must look like #rrggbb"
        )
        let side = InlineSprite.maxSide
        guard let height = frames.first?.count, let width = frames.first?.first?.utf16.count else {
            throw ValidationError("a sprite needs at least one frame with one row")
        }
        let sameSize = frames.allSatisfy { rows in
            rows.count == height && rows.allSatisfy { $0.utf16.count == width }
        }
        try require(
            sameSize && height <= side && width <= side,
            "all frames must share one size, at most \(side)×\(side)"
        )
    }
}

struct CardInput: Decodable {
    var key: String?
    var title: String
    var text: String?
    var sprite: SpriteReference?
    var actions: [ActionInput]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key, title, text, sprite, actions
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        actions = try container.decodeIfPresent([ActionInput].self, forKey: .actions) ?? []

        if let name = try? container.decodeIfPresent(String.self, forKey: .sprite) {
            try requireLength(name, "sprite", 1...unlimited)
            sprite = .named(name)
        } else if let inline = try container.decodeIfPresent(SpriteInput.self, forKey: .sprite) {
            sprite = .inline(InlineSprite(palette: inline.palette, frames: inline.frames, fps: inline.fps))
        }

        if let key { try requireLength(key, "key", 1...unlimited) }
        try requireLength(title, "title", 1...120)
        if let text { try requireLength(text, "text", 0...600) }
        try require(actions.count <= 4, "a card has at most 4 actions")
    }

    init(title: String, text: String?, sprite: SpriteReference, actions: [ActionInput]) {
        self.title = title
        self.text = text
        self.sprite = sprite
        self.actions = actions
    }
}

struct StatusInput: Decodable {
    var mood: Mood
    var text: String?
    var ttlSeconds: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mood, text, ttlSeconds
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mood = try container.decode(Mood.self, forKey: .mood)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        ttlSeconds = try container.decodeIfPresent(Double.self, forKey: .ttlSeconds) ?? 1800

        if let text { try requireLength(text, "text", 0...80) }
        try require(ttlSeconds > 0, "ttlSeconds must be positive")
    }

    init(mood: Mood, ttlSeconds: Double) {
        self.mood = mood
        self.ttlSeconds = ttlSeconds
    }
}

struct PressInput: Decodable {
    let index: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case index
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        index = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .index)
        try require(index >= 0, "index must not be negative")
    }
}

struct KeyInput: Decodable {
    let key: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        key = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .key)
        try requireLength(key, "key", 1...unlimited)
    }
}

struct IntegrationInput: Decodable {
    let isOn: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case isOn
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        isOn = try decoder.container(keyedBy: CodingKeys.self).decode(Bool.self, forKey: .isOn)
    }
}

struct AskInput: Decodable {
    var question: String
    var details: String?
    var options: [String]
    var timeoutSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case question, details, options, timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        options = try container.decode([String].self, forKey: .options)
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 300

        try requireLength(question, "question", 1...120)
        if let details { try requireLength(details, "details", 0...600) }
        try require((1...4).contains(options.count), "ask needs 1-4 options")
        for option in options { try requireLength(option, "option", 1...20) }
        try require(timeoutSeconds > 0, "timeoutSeconds must be positive")
    }
}
