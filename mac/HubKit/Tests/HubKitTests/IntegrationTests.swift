import Foundation
import Testing
@testable import HubKit

private let pullRequest = PullRequest(
    role: .author,
    repository: "product",
    number: 1,
    title: "Fix",
    url: "https://github.com/a/product/pull/1",
    author: "me",
    checks: "SUCCESS",
    reviewDecision: "APPROVED"
)

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    func record() {
        lock.withLock { calls += 1 }
    }
}

private func setGithub(_ test: TestHub, isOn: Bool) async throws -> Int {
    try await test.send("PUT", "/integrations/github", body: #"{"isOn":\#(isOn)}"#).status
}

@Suite struct Integrations {
    @Test func allAreOnWhereTheMacHasWhatTheyRead() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        #expect(await test.store.state.integrations.map(\.id) == [.orca, .claude, .github])
        #expect(await test.store.state.integrations.allSatisfy(\.isOn))
    }

    @Test func aNewBoardLeavesOffWhatTheMacLacks() async throws {
        let test = try await TestHub(isSetUp: { $0 == .claude })
        defer { Task { await test.stop() } }
        #expect(await test.store.state.integrations.filter(\.isOn).map(\.id) == [.claude])
    }

    @Test func aSavedChoiceOutlivesWhatTheMacHas() async throws {
        let test = try await TestHub(isSetUp: { _ in false })
        defer { Task { await test.stop() } }
        _ = try await setGithub(test, isOn: true)

        let reopened = Store(dataDirectory: test.dataDirectory, log: test.hub.log, isSetUp: { _ in false })
        #expect(await reopened.isOn(.github))
        #expect(await reopened.isOn(.orca) == false)
    }

    @Test func switchingGithubOffClearsItsLightsAndStopsAskingGh() async throws {
        let fetches = FetchCounter()
        let test = try await TestHub(fetchPullRequests: {
            fetches.record()
            return [pullRequest]
        })
        defer { Task { await test.stop() } }
        await test.hub.github.sync()
        #expect(await test.store.state.github.count == 1)

        #expect(try await setGithub(test, isOn: false) == 204)
        #expect(await test.store.state.github.isEmpty)

        let fetchesWhileOn = fetches.count
        #expect(await test.hub.github.sync() == false)
        #expect(fetches.count == fetchesWhileOn)
    }

    @Test func switchingGithubOnBringsItsLightsBackAtOnce() async throws {
        let test = try await TestHub(fetchPullRequests: { [pullRequest] })
        defer { Task { await test.stop() } }
        _ = try await setGithub(test, isOn: false)
        _ = try await setGithub(test, isOn: true)
        #expect(await test.store.state.github.count == 1)
    }

    @Test func claudeKeepsFollowingSessionsWhileOff() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        _ = try await test.send("PUT", "/integrations/claude", body: #"{"isOn":false}"#)
        _ = try await test.post("/claude-events", #"{"event":"UserPromptSubmit","session":"s1","cwd":"/x/deck"}"#)
        #expect(await test.store.state.claude.isEmpty)

        _ = try await test.send("PUT", "/integrations/claude", body: #"{"isOn":true}"#)
        #expect(await test.store.state.claude.map(\.project) == ["deck"])
    }

    @Test func settingsSeeASwitchFromTheBoard() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        var integrations = await test.store.watchIntegrations().makeAsyncIterator()
        #expect(await integrations.next()?.allSatisfy(\.isOn) == true)

        _ = try await setGithub(test, isOn: false)
        let switched = await integrations.next()
        #expect(switched?.filter(\.isOn).map(\.id) == [.orca, .claude])
    }

    @Test func rejectsAnUnknownIntegrationAndABadBody() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        #expect(try await test.send("PUT", "/integrations/slack", body: #"{"isOn":false}"#).status == 404)
        #expect(try await test.send("PUT", "/integrations/github", body: #"{"on":false}"#).status == 400)
    }

    @Test func aPullRequestAnsweredAfterSwitchingOffStaysHidden() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        _ = try await setGithub(test, isOn: false)
        let item = GithubItem(key: "k", group: .mine, light: .idle, title: "t", text: "", url: "")
        await test.store.setGithub([item])
        #expect(await test.store.state.github.isEmpty)
    }

    @Test func rememberedAcrossARestart() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        _ = try await setGithub(test, isOn: false)

        let reopened = Store(dataDirectory: test.dataDirectory, log: test.hub.log, isSetUp: { _ in true })
        #expect(await reopened.isOn(.github) == false)
        #expect(await reopened.isOn(.claude))
    }

    @Test func aStateFileFromBeforeTheCatalogKeepsItsCards() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        _ = try await test.createCard(#"{"title":"kept"}"#)
        let url = test.dataDirectory.appending(path: "state.json")
        var saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        saved["integrations"] = nil
        try JSONSerialization.data(withJSONObject: saved).write(to: url)

        let reopened = Store(dataDirectory: test.dataDirectory, log: test.hub.log, isSetUp: { _ in true })
        #expect(await reopened.state.cards.map(\.title) == ["kept"])
        #expect(await reopened.state.integrations == Integration.catalog)
    }
}
