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

private func changed(checks: String?, decision: String? = "REVIEW_REQUIRED") -> PullRequest {
    var pullRequest = authored
    pullRequest.checks = checks
    pullRequest.reviewDecision = decision
    return pullRequest
}

private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [PullRequest] = []
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

    var opened: [String] { lock.withLock { openedURLs } }

    func watcher() -> GithubWatcher {
        GithubWatcher(
            store: store,
            dataDirectory: dataDirectory,
            log: log,
            fetch: { [self] in pullRequests },
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
            openURL: { _ in }
        )
        #expect(await offline.sync() == false)
        #expect(await fixture.lights.count == 1)
    }
}
