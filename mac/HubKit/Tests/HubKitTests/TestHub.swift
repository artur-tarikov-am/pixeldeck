import Foundation
import Testing
@testable import HubKit

/// A hub on a free loopback port with its own data directory.
final class TestHub: Sendable {
    let hub: Hub
    let dataDirectory: URL
    let base: String

    init(
        actionsJSON: String? = nil,
        isSetUp: IsSetUp = { _ in true },
        fetchPullRequests: @escaping FetchPullRequests = { [] },
        fetchChats: @escaping FetchChats = { [] },
        openChat: @escaping OpenChat = { _ in },
        closeChat: @escaping CloseChat = { _ in },
        now: @escaping @Sendable () -> Date = { .now }
    ) async throws {
        dataDirectory = FileManager.default.temporaryDirectory.appending(path: "pixeldeck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        if let actionsJSON {
            try Data(actionsJSON.utf8).write(to: dataDirectory.appending(path: "actions.json"))
        }
        hub = Hub(
            dataDirectory: dataDirectory,
            log: HubLog(dataDirectory: dataDirectory),
            isSetUp: isSetUp,
            fetchPullRequests: fetchPullRequests,
            openURL: { _ in },
            fetchChats: fetchChats,
            openChat: openChat,
            closeChat: closeChat,
            now: now
        )
        let port = try await hub.start(port: 0, onFailure: { _ in })
        base = "http://127.0.0.1:\(port)"
    }

    var store: Store { hub.store }

    func send(
        _ method: String,
        _ path: String,
        body: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: try #require(URL(string: base + path)))
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func post(_ path: String, _ body: String) async throws -> Int {
        try await send("POST", path, body: body).status
    }

    func createCard(_ body: String) async throws -> String {
        let (status, data) = try await send("POST", "/cards", body: body)
        #expect(status == 201)
        return try JSONDecoder().decode(Card.self, from: data).id
    }

    func waitForAction(_ id: String, _ state: ActionState) async throws -> Card {
        for _ in 0..<400 {
            if let card = await store.card(id), card.actions[0].state == state { return card }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HTTPError(0, "action never reached \(state)")
    }

    func stop() async {
        await hub.stop()
        try? FileManager.default.removeItem(at: dataDirectory)
    }
}
