import Foundation

private struct ActionConfig: Decodable {
    let command: [String]
    let timeoutSeconds: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case command, timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode([String].self, forKey: .command)
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 120
        try require(!command.isEmpty, "command must not be empty")
        try require(timeoutSeconds > 0, "timeoutSeconds must be positive")
    }
}

public struct Actions: Sendable {
    private static let noteLength = 200

    private let url: URL

    public init(dataDirectory: URL) {
        url = dataDirectory.appending(path: "actions.json")
    }

    /// The file is reread on every use, so a new action works without restarting the hub.
    private func read() throws -> [String: ActionConfig] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: ActionConfig].self, from: Data(contentsOf: url))
    }

    func unknownRuns(in card: CardInput) throws -> [String] {
        let known = try read()
        return card.actions.compactMap(\.run).filter { known[$0] == nil }
    }

    func press(store: Store, cardId: String, index: Int) async -> Bool {
        switch await store.press(cardId: cardId, index: index) {
        case .notFound:
            return false
        case .handled:
            return true
        case .run(let name, let args):
            Task { await execute(name, args, store: store, cardId: cardId, index: index) }
            return true
        }
    }

    private func execute(_ name: String, _ args: [String], store: Store, cardId: String, index: Int) async {
        do {
            guard let action = try read()[name] else {
                throw SubprocessFailure(message: "unknown action \(name)")
            }
            _ = try await Subprocess.run(action.command + args, timeoutSeconds: action.timeoutSeconds)
            await store.setActionState(cardId: cardId, index: index, state: .done)
        } catch {
            let message = (error as? SubprocessFailure)?.message ?? String(describing: error)
            await store.setActionState(
                cardId: cardId, index: index, state: .failed, note: String(message.suffix(Self.noteLength))
            )
        }
    }
}
