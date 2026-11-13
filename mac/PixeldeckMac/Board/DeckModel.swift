import AppKit

enum Connection {
    case connecting, online, offline
}

enum RefreshSource: String {
    case orca, github
}

@MainActor
final class DeckModel {
    private static let streamIdleTimeout: TimeInterval = 40
    private static let reconnectDelay: Duration = .seconds(3)
    private static let answerTimeout: TimeInterval = 15

    private(set) var deck = Deck.empty
    private(set) var connection = Connection.connecting
    /// Moment of the latest card that was not on screen before; the character reacts to it.
    private(set) var lastArrival: Date?
    /// Hears each deck from the hub with the one it replaces, so a screen can tell what just happened.
    /// The first deck is not passed on: it only shows what was there before the screen came up.
    var onChange: ((_ old: Deck, _ new: Deck) -> Void)?
    private var hasDeck = false
    /// The hub runs in this app and listens on loopback.
    private let port: Int

    init(port: Int) {
        self.port = port
    }

    /// Keeps the stream open for as long as the screen is alive.
    func run() async {
        while !Task.isCancelled {
            await listen()
            connection = .offline
            try? await Task.sleep(for: Self.reconnectDelay)
        }
    }

    private func listen() async {
        connection = .connecting
        var request = hubRequest(path: "/stream")
        request.timeoutInterval = Self.streamIdleTimeout
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            connection = .online
            for try await line in bytes.lines where line.hasPrefix("data: ") {
                apply(try JSONDecoder().decode(Deck.self, from: Data(line.dropFirst(6).utf8)))
            }
        } catch {
            // Dropped connections are routine here; run() retries.
        }
    }

    private func apply(_ next: Deck) {
        let known = Set(deck.cards.map(\.id))
        if connection == .online, next.cards.contains(where: { !known.contains($0.id) }) {
            lastArrival = Date()
        }
        if hasDeck { onChange?(deck, next) }
        hasDeck = true
        deck = next
    }

    func press(card: Card, actionIndex: Int) {
        if let url = card.actions[actionIndex].url {
            NSWorkspace.shared.open(url)
            return
        }
        send(path: "/cards/\(card.id)/press", method: "POST", body: ["index": actionIndex])
    }

    func dismiss(card: Card) {
        send(path: "/cards/\(card.id)", method: "DELETE")
    }

    /// Returns whether the hub got fresh data.
    func refresh(_ source: RefreshSource) async -> Bool {
        await post(path: "/\(source.rawValue)-refreshes")
    }

    /// Returns whether the chat is gone.
    func closeChat(key: String) async -> Bool {
        await post(path: "/orca-closes", body: ["key": key])
    }

    func openOnMac(pullRequest card: Card) {
        send(path: "/github-opens", method: "POST", body: ["key": card.id])
    }

    func openChat(key: String) {
        send(path: "/orca-opens", method: "POST", body: ["key": key])
    }

    func mute(pullRequest card: Card) {
        send(path: "/github-mutes", method: "POST", body: ["key": card.id])
    }

    func toggle(_ integration: Integration) {
        send(path: "/integrations/\(integration.id)", method: "PUT", body: ["isOn": !integration.isOn])
    }

    private func post(path: String, body: (any Encodable)? = nil) async -> Bool {
        var request = hubRequest(path: path)
        request.httpMethod = "POST"
        request.httpBody = body.flatMap { try? JSONEncoder().encode($0) }
        request.timeoutInterval = Self.answerTimeout
        let response = try? await URLSession.shared.data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode == 204
    }

    private func send(path: String, method: String, body: (any Encodable)? = nil) {
        var request = hubRequest(path: path)
        request.httpMethod = method
        request.httpBody = body.flatMap { try? JSONEncoder().encode($0) }
        Task { _ = try? await URLSession.shared.data(for: request) }
    }

    private func hubRequest(path: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        guard let url = components.url else {
            preconditionFailure("a loopback address with a port always forms a valid URL")
        }
        return URLRequest(url: url)
    }
}
