import Foundation
import Testing
@testable import HubKit

private let authored = PullRequest(
    role: .author,
    repository: "product",
    number: 1,
    title: "Fix",
    url: "https://github.com/a/product/pull/1",
    author: "me",
    checks: "PENDING",
    reviewDecision: "REVIEW_REQUIRED"
)

private func reviewRequest() -> PullRequest {
    var pullRequest = authored
    pullRequest.role = .reviewer
    pullRequest.number = 2
    pullRequest.author = "colleague"
    return pullRequest
}

private let mention = Mention(
    id: "IC_1",
    number: 7,
    title: "Plan the release",
    author: "colleague",
    line: "@me what do you think?",
    url: "https://github.com/a/product/pull/7#issuecomment-1",
    createdAt: .now
)

private func changed(checks: String?, decision: String? = "REVIEW_REQUIRED") -> PullRequest {
    var pullRequest = authored
    pullRequest.checks = checks
    pullRequest.reviewDecision = decision
    return pullRequest
}

private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [PullRequest] = []
    private var currentMentions: [Mention] = []
    private var openedURLs: [String] = []

    let dataDirectory: URL
    let log: HubLog
    let store: Store
    private(set) var github: GithubWatcher!

    init() throws {
        dataDirectory = FileManager.default.temporaryDirectory.appending(path: "pixeldeck-github-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        log = HubLog(dataDirectory: dataDirectory)
        store = Store(dataDirectory: dataDirectory, log: log, isSetUp: { _ in true })
        github = watcher()
    }

    var pullRequests: [PullRequest] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var mentions: [Mention] {
        get { lock.withLock { currentMentions } }
        set { lock.withLock { currentMentions = newValue } }
    }

    var opened: [String] { lock.withLock { openedURLs } }

    func watcher() -> GithubWatcher {
        GithubWatcher(
            store: store,
            dataDirectory: dataDirectory,
            log: log,
            fetch: { [self] in pullRequests },
            fetchMentions: { [self] in mentions },
            openURL: { [self] url in lock.withLock { openedURLs.append(url) } }
        )
    }

    var lights: [Light] {
        get async { await store.state.github.map(\.light) }
    }
}

@Suite struct GithubLights {
    @Test func describesAPullRequest() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [authored]
        await fixture.github.sync()
        let item = try #require(await fixture.store.state.github.first)
        #expect(item.title == "#1 Fix")
        #expect(item.text == "CI running, awaiting review")
        #expect(item.group == .mine)
    }

    @Test(arguments: [
        (changed(checks: "FAILURE"), Light.failed),
        (changed(checks: "SUCCESS", decision: "CHANGES_REQUESTED"), .waiting),
        (changed(checks: "SUCCESS", decision: "APPROVED"), .done),
        (changed(checks: "SUCCESS"), .idle),
        (changed(checks: "PENDING"), .running),
    ] as [(PullRequest, Light)])
    func lights(pullRequest: PullRequest, expected: Light) async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [pullRequest]
        await fixture.github.sync()
        #expect(await fixture.lights == [expected])
    }

    @Test func groupsReviewRequestsSeparately() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [reviewRequest()]
        await fixture.github.sync()
        let item = try #require(await fixture.store.state.github.first)
        #expect(item.light == .review)
        #expect(item.group == .review)
        #expect(item.text == "review for colleague")
    }

    @Test func keepsAMutedLightOffUntilThePullRequestChanges() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [authored]
        await fixture.github.sync()
        #expect(await fixture.github.mute(key: "product-1"))
        #expect(await fixture.lights == [])
        await fixture.github.sync()
        #expect(await fixture.lights == [])

        fixture.pullRequests = [changed(checks: "FAILURE")]
        await fixture.github.sync()
        #expect(await fixture.lights == [.failed])
    }

    @Test func aReviewRequestStaysMutedWhenOnlyItsChecksChange() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [reviewRequest()]
        await fixture.github.sync()
        #expect(await fixture.github.mute(key: "product-2"))
        var running = reviewRequest()
        running.checks = "FAILURE"
        fixture.pullRequests = [running]
        await fixture.github.sync()
        #expect(await fixture.lights == [])
    }

    @Test func remembersAMuteAcrossARestart() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [authored]
        await fixture.github.sync()
        #expect(await fixture.github.mute(key: "product-1"))
        await fixture.watcher().sync()
        #expect(await fixture.lights == [])
    }

    @Test func opensThePullRequestByKey() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [authored]
        await fixture.github.sync()
        #expect(await fixture.github.open(key: "product-1"))
        #expect(fixture.opened == [authored.url])
    }

    @Test func refusesToOpenAnythingGithubDidNotReport() async throws {
        let fixture = try Fixture()
        #expect(await fixture.github.open(key: "https://evil.example") == false)
        #expect(fixture.opened.isEmpty)
    }

    @Test func refusesToMuteAnUnknownPullRequest() async throws {
        let fixture = try Fixture()
        #expect(await fixture.github.mute(key: "product-404") == false)
    }

    @Test func switchesTheLightOffWhenThePullRequestIsGone() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [authored]
        await fixture.github.sync()
        fixture.pullRequests = []
        await fixture.github.sync()
        #expect(await fixture.lights == [])
    }

    @Test func keepsLightsOnWhenGithubCannotBeReached() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [authored]
        #expect(await fixture.github.sync())
        let offline = GithubWatcher(
            store: fixture.store,
            dataDirectory: fixture.dataDirectory,
            log: fixture.log,
            fetch: { throw HTTPError(0, "offline") },
            fetchMentions: { [] },
            openURL: { _ in }
        )
        #expect(await offline.sync() == false)
        #expect(await fixture.lights.count == 1)
    }
}

@Suite struct GithubMentions {
    @Test func describesAMention() async throws {
        let fixture = try Fixture()
        fixture.mentions = [mention]
        await fixture.github.sync()
        let item = try #require(await fixture.store.state.github.first)
        #expect(item.key == "mention-IC_1")
        #expect(item.group == .mention)
        #expect(item.light == .waiting)
        #expect(item.title == "#7 Plan the release")
        #expect(item.text == "colleague: @me what do you think?")
    }

    @Test func listsMentionsBeforePullRequests() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [authored]
        fixture.mentions = [mention]
        await fixture.github.sync()
        #expect(await fixture.store.state.github.map(\.group) == [.mention, .mine])
    }

    @Test func anOpenedMentionIsRead() async throws {
        let fixture = try Fixture()
        fixture.mentions = [mention]
        await fixture.github.sync()
        #expect(await fixture.github.open(key: "mention-IC_1"))
        #expect(fixture.opened == [mention.url])
        #expect(await fixture.lights == [])
        await fixture.github.sync()
        #expect(await fixture.lights == [])
    }

    @Test func anOpenedPullRequestStays() async throws {
        let fixture = try Fixture()
        fixture.pullRequests = [authored]
        await fixture.github.sync()
        #expect(await fixture.github.open(key: "product-1"))
        #expect(await fixture.lights.count == 1)
    }

    @Test func aNewerMentionInTheSameThreadLightsUpAgain() async throws {
        let fixture = try Fixture()
        fixture.mentions = [mention]
        await fixture.github.sync()
        #expect(await fixture.github.mute(key: "mention-IC_1"))
        var newer = mention
        newer.id = "IC_2"
        fixture.mentions = [newer]
        await fixture.github.sync()
        #expect(await fixture.lights == [.waiting])
    }
}

@Suite struct ReadingMentions {
    private let thread = MentionThread(
        id: "1", updatedAt: "2026-11-06T10:00:00Z", owner: "a", repository: "product", number: 7, title: "Plan"
    )

    /// Shaped like the answer of `GithubCommands.threadQuery`.
    private let answer = #"""
        {"data": {"viewer": {"login": "me"}, "repository": {"issueOrPullRequest": {
          "id": "PR_1", "body": "Adds the plan", "createdAt": "2026-11-01T10:00:00Z",
          "author": {"kind": "User", "login": "colleague"}, "url": "https://github.com/a/product/pull/7",
          "comments": {"nodes": [
            {"id": "IC_1", "body": "@me can you look?", "createdAt": "2026-11-02T10:00:00Z",
             "author": {"kind": "User", "login": "colleague"}, "url": "https://github.com/a/product/pull/7#issuecomment-1"},
            {"id": "IC_2", "body": "Merge gate overridden by @me", "createdAt": "2026-11-05T10:00:00Z",
             "author": {"kind": "Bot", "login": "merge-gate"}, "url": "https://github.com/a/product/pull/7#issuecomment-2"},
            {"id": "IC_3", "body": "Gone", "createdAt": "2026-11-05T11:00:00Z",
             "author": null, "url": "https://github.com/a/product/pull/7#issuecomment-3"}
          ]},
          "reviews": {"nodes": [
            {"id": "PRR_1", "body": "", "createdAt": "2026-11-03T10:00:00Z",
             "author": {"kind": "User", "login": "lead"}, "url": "https://github.com/a/product/pull/7#pullrequestreview-1",
             "comments": {"nodes": [
               {"id": "PRRC_1", "body": "Not sure.\nLet's ask @me", "createdAt": "2026-11-03T10:00:00Z",
                "author": {"kind": "User", "login": "lead"}, "url": "https://github.com/a/product/pull/7#discussion_r1"}
             ]}},
            {"id": "PRR_2", "body": "> @me fixed it?\nYes", "createdAt": "2026-11-04T10:00:00Z",
             "author": {"kind": "User", "login": "lead"}, "url": "https://github.com/a/product/pull/7#pullrequestreview-2",
             "comments": {"nodes": []}},
            {"id": "PRR_3", "body": "cc @me", "createdAt": "2026-11-06T10:00:00Z",
             "author": {"kind": "User", "login": "me"}, "url": "https://github.com/a/product/pull/7#pullrequestreview-3",
             "comments": {"nodes": []}}
          ]}
        }}}}
        """#

    @Test func findsTheNewestMentionByAnotherPerson() throws {
        let found = try #require(try GithubCommands.latestMention(in: thread, answer: Data(answer.utf8)))
        #expect(found.id == "PRRC_1")
        #expect(found.author == "lead")
        #expect(found.line == "Let's ask @me")
        #expect(found.url == "https://github.com/a/product/pull/7#discussion_r1")
        #expect(found.number == 7)
        #expect(found.title == "Plan")
    }

    @Test(arguments: [
        ("ping @me please", "ping @me please"),
        ("first line\n  @ME, look  ", "@ME, look"),
        ("> @me said so", nil),
        ("@me-two, hi", nil),
        ("write to name@me", nil),
    ] as [(String, String?)])
    func findsTheLineWithTheMention(body: String, expected: String?) {
        #expect(GithubCommands.mentionLine(of: "me", in: body) == expected)
    }
}
