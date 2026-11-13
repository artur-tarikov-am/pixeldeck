import Foundation

public struct PullRequest: Sendable {
    public enum Role: String, Sendable {
        case author, reviewer
    }

    var role: Role
    var repository: String
    var number: Int
    var title: String
    var url: String
    var author: String
    var checks: String?
    var reviewDecision: String?
}

public typealias FetchPullRequests = @Sendable () async throws -> [PullRequest]
public typealias OpenURL = @Sendable (String) -> Void

private struct GraphqlPullRequest: Decodable {
    struct Author: Decodable { let login: String }
    struct Repository: Decodable { let name: String }
    struct Rollup: Decodable { let state: String }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commits: Decodable { let nodes: [CommitNode] }

    let number: Int
    let title: String
    let url: String
    let reviewDecision: String?
    let author: Author?
    let repository: Repository
    let commits: Commits

    func pullRequest(role: PullRequest.Role) -> PullRequest {
        PullRequest(
            role: role,
            repository: repository.name,
            number: number,
            title: title,
            url: url,
            author: author?.login ?? "unknown",
            checks: commits.nodes.first?.commit.statusCheckRollup?.state,
            reviewDecision: reviewDecision
        )
    }
}

private struct GraphqlAnswer: Decodable {
    struct Search: Decodable { let nodes: [GraphqlPullRequest] }
    struct Payload: Decodable {
        let authored: Search
        let review: Search
    }

    let data: Payload
}

public enum GithubCommands {
    private static let timeoutSeconds: Double = 30
    private static let authoredSearch = "is:open is:pr draft:false author:@me archived:false"
    private static let reviewSearch = "is:open is:pr draft:false review-requested:@me archived:false"
    private static let query = """
        query($authored: String!, $review: String!) {
          authored: search(query: $authored, type: ISSUE, first: 25) { nodes { ...pullRequest } }
          review: search(query: $review, type: ISSUE, first: 25) { nodes { ...pullRequest } }
        }
        fragment pullRequest on PullRequest {
          number
          title
          url
          reviewDecision
          author { login }
          repository { name }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        }
        """

    /// `gh auth login` writes it.
    static var hasLogin: Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/gh/hosts.yml")
                .path(percentEncoded: false)
        )
    }

    public static let fetchPullRequests: FetchPullRequests = {
        let output = try await Subprocess.run(
            [
                "gh", "api", "graphql",
                "-f", "query=\(query)",
                "-f", "authored=\(authoredSearch)",
                "-f", "review=\(reviewSearch)",
            ],
            timeoutSeconds: timeoutSeconds
        )
        let answer = try JSONDecoder().decode(GraphqlAnswer.self, from: output).data
        return answer.authored.nodes.map { $0.pullRequest(role: .author) }
            + answer.review.nodes.map { $0.pullRequest(role: .reviewer) }
    }

    public static func openInMacBrowser(log: HubLog) -> OpenURL {
        { url in
            Task {
                do {
                    _ = try await Subprocess.run(["/usr/bin/open", url], timeoutSeconds: timeoutSeconds)
                } catch {
                    log.write("could not open pull request: \(error)")
                }
            }
        }
    }
}

private func checksText(_ checks: String?) -> String {
    switch checks {
    case "SUCCESS": "CI ok"
    case "FAILURE", "ERROR": "CI failed"
    case "PENDING", "EXPECTED": "CI running"
    default: "no CI"
    }
}

private func reviewText(_ decision: String?) -> String {
    switch decision {
    case "APPROVED": "approved"
    case "CHANGES_REQUESTED": "changes requested"
    default: "awaiting review"
    }
}

private func authoredLight(_ pullRequest: PullRequest) -> Light {
    let checks = pullRequest.checks
    let decision = pullRequest.reviewDecision
    if checks == "FAILURE" || checks == "ERROR" { return .failed }
    if decision == "CHANGES_REQUESTED" { return .waiting }
    if checks == "PENDING" || checks == "EXPECTED" { return .running }
    return checks == "SUCCESS" && decision == "APPROVED" ? .done : .idle
}

private func item(for pullRequest: PullRequest) -> GithubItem {
    let isMine = pullRequest.role == .author
    return GithubItem(
        key: "\(pullRequest.repository)-\(pullRequest.number)",
        group: isMine ? .mine : .review,
        light: isMine ? authoredLight(pullRequest) : .review,
        title: String("#\(pullRequest.number) \(pullRequest.title)".prefix(120)),
        text: isMine
            ? "\(checksText(pullRequest.checks)), \(reviewText(pullRequest.reviewDecision))"
            : "review for \(pullRequest.author)",
        url: pullRequest.url
    )
}

/// What has to change for a pull request the user muted to light up again.
private func fingerprint(_ pullRequest: PullRequest) -> String {
    let parts: [String?] = pullRequest.role == .reviewer
        ? [pullRequest.role.rawValue, pullRequest.title]
        : [pullRequest.role.rawValue, pullRequest.title, pullRequest.checks, pullRequest.reviewDecision]
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return (try? encoder.encode(parts)).map { String(decoding: $0, as: UTF8.self) } ?? ""
}

public actor GithubWatcher {
    private static let pollInterval: Double = 60

    private struct Entry {
        let item: GithubItem
        let fingerprint: String
    }

    private let store: Store
    private let log: HubLog
    private let fetch: FetchPullRequests
    private let openURL: OpenURL
    private let url: URL
    private var muted: [String: String]
    private var latest: [Entry] = []
    private var polling: Task<Void, Never>?

    public init(
        store: Store,
        dataDirectory: URL,
        log: HubLog,
        fetch: @escaping FetchPullRequests = GithubCommands.fetchPullRequests,
        openURL: OpenURL? = nil
    ) {
        self.store = store
        self.log = log
        self.fetch = fetch
        self.openURL = openURL ?? GithubCommands.openInMacBrowser(log: log)
        url = dataDirectory.appending(path: "github-muted.json")
        muted = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    func start() {
        polling = Task {
            repeat {
                await sync()
            } while (try? await sleep(seconds: Self.pollInterval)) != nil
        }
    }

    func stop() {
        polling?.cancel()
    }

    /// Returns whether GitHub answered.
    @discardableResult
    func sync() async -> Bool {
        guard await store.isOn(.github) else { return false }
        do {
            latest = try await fetch().map { Entry(item: item(for: $0), fingerprint: fingerprint($0)) }
        } catch {
            // Offline or an expired login must not switch off the lights already on screen.
            log.write("github sync failed: \(error)")
            return false
        }
        forgetOutdatedMutes()
        await publish()
        return true
    }

    /// Takes a key, not a URL, so the board can only open what GitHub reported.
    func open(key: String) -> Bool {
        guard let entry = latest.first(where: { $0.item.key == key }) else { return false }
        openURL(entry.item.url)
        return true
    }

    func mute(key: String) async -> Bool {
        guard let entry = latest.first(where: { $0.item.key == key }) else { return false }
        muted[key] = entry.fingerprint
        saveMutes()
        await publish()
        return true
    }

    private func forgetOutdatedMutes() {
        let current = Dictionary(latest.map { ($0.item.key, $0.fingerprint) }) { first, _ in first }
        muted = muted.filter { current[$0.key] == $0.value }
        saveMutes()
    }

    private func publish() async {
        await store.setGithub(latest.filter { muted[$0.item.key] != $0.fingerprint }.map(\.item))
    }

    private func saveMutes() {
        do {
            try JSONEncoder().encode(muted).write(to: url, options: .atomic)
        } catch {
            log.write("could not save muted pull requests: \(error)")
        }
    }
}
