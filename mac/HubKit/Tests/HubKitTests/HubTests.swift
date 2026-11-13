import Foundation
import Testing
@testable import HubKit

private let actionsJSON = #"""
{
  "succeed": { "command": ["true"] },
  "fail": { "command": ["sh", "-c", "echo nope >&2; exit 3"] },
  "slow": { "command": ["sleep", "5"], "timeoutSeconds": 0.2 }
}
"""#

@Suite struct Cards {
    @Test func rejectsAnActionWithBothAUrlAndARun() async throws {
        let test = try await TestHub(actionsJSON: actionsJSON)
        defer { Task { await test.stop() } }
        let status = try await test.post("/cards", #"{"title":"x","actions":[{"label":"a","url":"https://example.com","run":"succeed"}]}"#)
        #expect(status == 400)
    }

    @Test func rejectsARunThatIsNotInTheConfig() async throws {
        let test = try await TestHub(actionsJSON: actionsJSON)
        defer { Task { await test.stop() } }
        let status = try await test.post("/cards", #"{"title":"x","actions":[{"label":"a","run":"rm-everything"}]}"#)
        #expect(status == 400)
        #expect(await test.store.state.cards.isEmpty)
    }

    @Test func replacesTheCardWithTheSameKey() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let first = try await test.createCard(#"{"key":"pr-1","title":"old"}"#)
        let second = try await test.createCard(#"{"key":"pr-1","title":"new"}"#)
        #expect(first == second)
        #expect(await test.store.state.cards.map(\.title) == ["new"])
    }

    @Test func rejectsInlineSpriteFramesOfDifferentSizes() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let status = try await test.post("/cards", ##"{"title":"x","sprite":{"palette":{"a":"#ffffff"},"frames":[["aa"],["a"]]}}"##)
        #expect(status == 400)
    }

    @Test(arguments: [
        "not json",
        "[]",
        "{}",
        #"{"title":""}"#,
        #"{"title":"x","extra":1}"#,
        #"{"title":"x","actions":[{"label":"","reply":"y"}]}"#,
        #"{"title":"x","actions":[{"label":"a","url":"no scheme"}]}"#,
    ])
    func answersBadInputWith400(body: String) async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        #expect(try await test.post("/cards", body) == 400)
    }

    @Test func keepsInlineSpritesInTheStream() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let id = try await test.createCard(##"{"title":"x","sprite":{"palette":{"a":"#ffffff"},"frames":[["a."]]}}"##)
        let card = try #require(await test.store.card(id))
        #expect(card.sprite == .inline(InlineSprite(palette: ["a": "#ffffff"], frames: [["a."]], fps: 4)))
    }

    @Test func aRestartKeepsCardsAndForgetsInterruptedRuns() async throws {
        let test = try await TestHub(actionsJSON: actionsJSON)
        defer { Task { await test.stop() } }
        let id = try await test.createCard(#"{"title":"x","actions":[{"label":"a","run":"succeed"}]}"#)
        await test.store.setActionState(cardId: id, index: 0, state: .running)

        let log = HubLog(dataDirectory: test.dataDirectory)
        let reloaded = await Store(dataDirectory: test.dataDirectory, log: log, isSetUp: { _ in true }).state
        #expect(reloaded.cards.first?.actions.first?.state == .idle)
    }
}

@Suite struct Security {
    @Test func refusesBrowserRequestsEvenFromLoopback() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let (status, _) = try await test.send("GET", "/cards", headers: ["Origin": "https://evil.example"])
        #expect(status == 403)
    }

    @Test func healthAnswersWithoutAnything() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let (status, data) = try await test.send("GET", "/health")
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
    }

    @Test func refusesAnUnknownEndpoint() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        #expect(try await test.send("GET", "/nothing").status == 404)
    }

    @Test func refusesATooLargeBody() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let body = String(repeating: "x", count: 1_000_001)
        #expect(try await test.post("/cards", body) == 413)
    }
}

@Suite struct Pressing {
    @Test func marksASuccessfulRunAsDone() async throws {
        let test = try await TestHub(actionsJSON: actionsJSON)
        defer { Task { await test.stop() } }
        let id = try await test.createCard(#"{"title":"x","actions":[{"label":"a","run":"succeed"}]}"#)
        #expect(try await test.post("/cards/\(id)/press", #"{"index":0}"#) == 202)
        _ = try await test.waitForAction(id, .done)
    }

    @Test func showsWhyARunFailed() async throws {
        let test = try await TestHub(actionsJSON: actionsJSON)
        defer { Task { await test.stop() } }
        let id = try await test.createCard(#"{"title":"x","actions":[{"label":"a","run":"fail"}]}"#)
        _ = try await test.post("/cards/\(id)/press", #"{"index":0}"#)
        #expect(try await test.waitForAction(id, .failed).note == "nope")
    }

    @Test func stopsARunThatTakesTooLong() async throws {
        let test = try await TestHub(actionsJSON: actionsJSON)
        defer { Task { await test.stop() } }
        let id = try await test.createCard(#"{"title":"x","actions":[{"label":"a","run":"slow"}]}"#)
        _ = try await test.post("/cards/\(id)/press", #"{"index":0}"#)
        _ = try await test.waitForAction(id, .failed)
    }

    @Test func refusesAMissingAction() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let id = try await test.createCard(#"{"title":"x"}"#)
        #expect(try await test.post("/cards/\(id)/press", #"{"index":0}"#) == 404)
    }

    @Test func deliversAReplyToTheWaitingCallerAndRemovesTheCard() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let id = try await test.createCard(#"{"title":"x","actions":[{"label":"Yes","reply":"yes"}]}"#)
        async let waiting = test.send("GET", "/cards/\(id)/answer?timeout=5")
        try await Task.sleep(for: .milliseconds(50))
        _ = try await test.post("/cards/\(id)/press", #"{"index":0}"#)
        #expect(String(decoding: try await waiting.data, as: UTF8.self) == #"{"answer":"yes"}"#)
        #expect(await test.store.card(id) == nil)
    }

    @Test func keepsAReplyForACallerThatStartsWaitingAfterwards() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let id = try await test.createCard(#"{"title":"x","actions":[{"label":"Yes","reply":"yes"}]}"#)
        _ = try await test.post("/cards/\(id)/press", #"{"index":0}"#)
        let (_, data) = try await test.send("GET", "/cards/\(id)/answer?timeout=1")
        #expect(String(decoding: data, as: UTF8.self) == #"{"answer":"yes"}"#)
    }

    @Test func answersNullWhenTheCardIsDismissed() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let id = try await test.createCard(#"{"title":"x","actions":[{"label":"Yes","reply":"yes"}]}"#)
        async let waiting = test.send("GET", "/cards/\(id)/answer?timeout=5")
        try await Task.sleep(for: .milliseconds(50))
        _ = try await test.send("DELETE", "/cards/\(id)")
        #expect(String(decoding: try await waiting.data, as: UTF8.self) == #"{"answer":null}"#)
    }

    @Test func answersNullWhenTheTimeRunsOut() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let id = try await test.createCard(#"{"title":"x","actions":[{"label":"Yes","reply":"yes"}]}"#)
        let (_, data) = try await test.send("GET", "/cards/\(id)/answer?timeout=0.05")
        #expect(String(decoding: data, as: UTF8.self) == #"{"answer":null}"#)
    }
}

@Suite struct Stream {
    private func firstEvents(_ test: TestHub, count: Int, during action: @Sendable () async throws -> Void) async throws -> [DeckState] {
        let url = try #require(URL(string: test.base + "/stream"))
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var iterator = bytes.lines.makeAsyncIterator()
        var events: [DeckState] = []
        while events.count < count, let line = try await iterator.next() {
            guard line.hasPrefix("data: ") else { continue }
            events.append(try JSONDecoder().decode(DeckState.self, from: Data(line.dropFirst(6).utf8)))
            if events.count == 1 { try await action() }
        }
        return events
    }

    @Test func sendsTheSnapshotAndThenEveryChange() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let events = try await firstEvents(test, count: 2) {
            _ = try await test.createCard(#"{"title":"hello"}"#)
        }
        #expect(events[0].cards.isEmpty)
        #expect(events[1].cards.map(\.title) == ["hello"])
    }
}

@Suite struct Restarting {
    @Test func stopsAndStartsAgainOnTheSameHub() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        #expect(try await test.send("GET", "/health").status == 200)
        await test.hub.stop()
        await #expect(throws: (any Error).self) { try await test.send("GET", "/health") }
        _ = try await test.hub.start(port: 0, onFailure: { _ in })
    }
}

@Suite struct Starting {
    @Test func aCancelledStartDoesNotPretendToListen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pixeldeck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hub = Hub(dataDirectory: directory, log: HubLog(dataDirectory: directory), fetchPullRequests: { [] })
        let start = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await hub.start(port: 0, onFailure: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await start.value }
    }
}

@Suite struct PullToRefresh {
    @Test func asksGithubAgain() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        #expect(try await test.send("POST", "/github-refreshes").status == 204)
    }

    @Test func reportsAFailedRefresh() async throws {
        let test = try await TestHub(fetchPullRequests: { throw HTTPError(0, "offline") })
        defer { Task { await test.stop() } }
        #expect(try await test.send("POST", "/github-refreshes").status == 502)
    }
}

@Suite struct Mcp {
    private func rpc(_ test: TestHub, _ body: String) async throws -> [String: Any] {
        let (status, data) = try await test.send("POST", "/mcp", body: body)
        #expect(status == 200)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func call(_ test: TestHub, _ name: String, _ arguments: String) async throws -> (text: String, isError: Bool) {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
        let result = try #require(try await rpc(test, body)["result"] as? [String: Any])
        let content = try #require((result["content"] as? [[String: Any]])?.first)
        return (try #require(content["text"] as? String), result["isError"] as? Bool ?? false)
    }

    @Test func agreesOnAProtocolVersion() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let answer = try await rpc(test, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
    }

    @Test func listsTheFiveTools() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let answer = try await rpc(test, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require((answer["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["show_card", "set_status", "ask", "remove_card", "list_cards"])
    }

    @Test func acceptsNotificationsWithoutAnAnswer() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let (status, data) = try await test.send("POST", "/mcp", body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(status == 202)
        #expect(data.isEmpty)
    }

    @Test func refusesAnUnknownMethod() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let answer = try await rpc(test, #"{"jsonrpc":"2.0","id":"a","method":"foo/bar"}"#)
        #expect(answer["id"] as? String == "a")
        #expect((answer["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func showsAndRemovesACard() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let shown = try await call(test, "show_card", #"{"title":"hi"}"#)
        let id = try #require(try JSONDecoder().decode([String: String].self, from: Data(shown.text.utf8))["id"])
        #expect(try await call(test, "list_cards", "{}").text.contains("hi"))
        #expect(try await call(test, "remove_card", #"{"id":"\#(id)"}"#).text == "ok")
        #expect(try await call(test, "remove_card", #"{"id":"\#(id)"}"#).isError)
    }

    @Test func reportsBadArgumentsAsAToolError() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        #expect(try await call(test, "set_status", #"{"mood":"zzz"}"#).isError)
        #expect(try await call(test, "nope", "{}").isError)
    }

    @Test func askWaitsForATap() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        async let answer = call(test, "ask", #"{"question":"Ship?","options":["Yes","No"]}"#)
        var card: Card?
        while card == nil {
            card = await test.store.state.cards.first
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try await test.post("/cards/\(try #require(card).id)/press", #"{"index":1}"#)
        #expect(try await answer.text == "No")
    }

    @Test func askRemovesTheCardWhenNobodyAnswers() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        let answer = try await call(test, "ask", #"{"question":"Ship?","options":["Yes"],"timeoutSeconds":0.05}"#)
        #expect(answer.text == "no answer")
        #expect(await test.store.state.cards.isEmpty)
    }
}
