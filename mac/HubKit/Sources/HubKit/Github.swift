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
    /// People, not bots, whose latest review approves it.
    var approvedBy: [String] = []
}

/// The newest post in a pull request or issue in which someone called the user by `@login`.
public struct Mention: Sendable {
    var id: String
    var number: Int
    var title: String
    var author: String
    /// The line of the post that holds the mention.
    var line: String
    var url: String
    var createdAt: Date
}

/// A pull request or issue in which GitHub says the user was mentioned.
struct MentionThread: Sendable {
    var id: String
    var updatedAt: String
    var owner: String
    var repository: String
    var number: Int
    var title: String
}

public typealias FetchPullRequests = @Sendable () async throws -> [PullRequest]
public typealias FetchMentions = @Sendable () async throws -> [Mention]
public typealias OpenURL = @Sendable (String) -> Void

private struct GraphqlPullRequest: Decodable {
    struct Author: Decodable { let login: String }
    struct Repository: Decodable { let name: String }
    struct Rollup: Decodable { let state: String }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commits: Decodable { let nodes: [CommitNode] }
    struct Review: Decodable {
        let state: String
        let author: GraphqlPost.Author?
    }

    struct Reviews: Decodable { let nodes: [Review] }

    let number: Int
    let title: String
    let url: String
    let reviewDecision: String?
    let author: Author?
    let repository: Repository
    let commits: Commits
    let latestOpinionatedReviews: Reviews

    func pullRequest(role: PullRequest.Role) -> PullRequest {
        PullRequest(
            role: role,
            repository: repository.name,
            number: number,
            title: title,
            url: url,
            author: author?.login ?? "unknown",
            checks: commits.nodes.first?.commit.statusCheckRollup?.state,
            reviewDecision: reviewDecision,
            approvedBy: latestOpinionatedReviews.nodes.compactMap { review in
                guard review.state == "APPROVED", let author = review.author, author.kind == "User" else { return nil }
                return author.login
            }
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

/// An issue or pull request, or a comment or review on one.
private struct GraphqlPost: Decodable {
    struct Author: Decodable {
        let kind: String
        let login: String
    }

    struct Posts: Decodable { let nodes: [GraphqlPost] }

    let id: String
    let body: String
    let createdAt: Date
    let author: Author?
    let url: String
    let comments: Posts?
    let reviews: Posts?

    /// The post and everything said under it.
    var thread: [GraphqlPost] {
        [self] + [comments, reviews].flatMap { $0?.nodes ?? [] }.flatMap(\.thread)
    }
}

private struct GraphqlThreadAnswer: Decodable {
    struct Viewer: Decodable { let login: String }
    struct Repository: Decodable { let issueOrPullRequest: GraphqlPost? }
    struct Payload: Decodable {
        let viewer: Viewer
        let repository: Repository?
    }

    let data: Payload
}

private struct NotificationThread: Decodable {
    struct Subject: Decodable {
        let title: String
        let url: String?
    }

    let id: String
    let reason: String
    let updatedAt: String
    let subject: Subject

    enum CodingKeys: String, CodingKey {
        case id, reason, subject
        case updatedAt = "updated_at"
    }

    /// Read from `https://api.github.com/repos/<owner>/<name>/pulls/<number>`, or `issues` for an issue.
    /// Discussions, commits and releases have no such address and are left out.
    var mentionThread: MentionThread? {
        guard let parts = subject.url?.split(separator: "/"), parts.count >= 4,
              ["pulls", "issues"].contains(parts[parts.count - 2]),
              let number = Int(parts[parts.count - 1])
        else { return nil }
        return MentionThread(
            id: id,
            updatedAt: updatedAt,
            owner: String(parts[parts.count - 4]),
            repository: String(parts[parts.count - 3]),
            number: number,
            title: subject.title
        )
    }
}

/// Remembers the mention found in each thread, so a thread is read again only after something new happens in it.
actor MentionReader {
    private struct Seen {
        let updatedAt: String
        let mention: Mention?
    }

    private let log: HubLog
    private var seen: [String: Seen] = [:]

    init(log: HubLog) {
        self.log = log
    }

    func read() async throws -> [Mention] {
        let since = Date.now.addingTimeInterval(-GithubCommands.mentionWindow)
        var kept: [String: Seen] = [:]
        for thread in try await GithubCommands.mentionThreads(since: since) {
            if let known = seen[thread.id], known.updatedAt == thread.updatedAt {
                kept[thread.id] = known
                continue
            }
            do {
                let answer = try await GithubCommands.readThread(thread)
                kept[thread.id] = Seen(
                    updatedAt: thread.updatedAt,
                    mention: try GithubCommands.latestMention(in: thread, answer: answer)
                )
            } catch {
                // One repository out of reach must not stop the rest of GitHub; the thread is read again next time.
                log.write("could not read mentions in \(thread.repository)#\(thread.number): \(error)")
            }
        }
        seen = kept
        return kept.values.compactMap(\.mention)
            .filter { $0.createdAt >= since }
            .sorted { $0.createdAt > $1.createdAt }
    }
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
          latestOpinionatedReviews(first: 20) { nodes { state author { kind: __typename login } } }
        }
        """
    /// How long a mention stays on the board; older ones are left to the GitHub inbox.
    static let mentionWindow: TimeInterval = 7 * 24 * 60 * 60
    private static let threadQuery = """
        query($owner: String!, $name: String!, $number: Int!) {
          viewer { login }
          repository(owner: $owner, name: $name) {
            issueOrPullRequest(number: $number) {
              ... on Issue { ...post comments(last: 50) { nodes { ...post } } }
              ... on PullRequest {
                ...post
                comments(last: 50) { nodes { ...post } }
                reviews(last: 50) { nodes { ...post comments(first: 50) { nodes { ...post } } } }
              }
            }
          }
        }
        fragment post on Comment {
          id
          body
          createdAt
          author { kind: __typename login }
          ... on Issue { url }
          ... on PullRequest { url }
          ... on IssueComment { url }
          ... on PullRequestReview { url }
          ... on PullRequestReviewComment { url }
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

    public static func fetchMentions(log: HubLog) -> FetchMentions {
        let reader = MentionReader(log: log)
        return { try await reader.read() }
    }

    /// Unread threads updated since `since`. GitHub keeps the reason `mention` on a thread through later
    /// activity, so the thread itself has to be read to find out who called the user and when.
    static func mentionThreads(since: Date) async throws -> [MentionThread] {
        let output = try await Subprocess.run(
            [
                "gh", "api", "--paginate", "--slurp",
                "notifications?participating=true&per_page=100&since=\(since.ISO8601Format())",
            ],
            timeoutSeconds: timeoutSeconds
        )
        return try JSONDecoder().decode([[NotificationThread]].self, from: output)
            .joined()
            .filter { $0.reason == "mention" }
            .compactMap(\.mentionThread)
    }

    static func readThread(_ thread: MentionThread) async throws -> Data {
        try await Subprocess.run(
            [
                "gh", "api", "graphql",
                "-f", "query=\(threadQuery)",
                "-f", "owner=\(thread.owner)",
                "-f", "name=\(thread.repository)",
                "-F", "number=\(thread.number)",
            ],
            timeoutSeconds: timeoutSeconds
        )
    }

    /// The newest post in which a person other than the user calls them. Bots are left out:
    /// they mention the author of a pull request in every status report.
    static func latestMention(in thread: MentionThread, answer: Data) throws -> Mention? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(GraphqlThreadAnswer.self, from: answer).data
        let login = payload.viewer.login
        let mentions = (payload.repository?.issueOrPullRequest?.thread ?? []).compactMap { post -> Mention? in
            guard let author = post.author, author.kind == "User",
                  author.login.caseInsensitiveCompare(login) != .orderedSame,
                  let line = mentionLine(of: login, in: post.body)
            else { return nil }
            return Mention(
                id: post.id,
                number: thread.number,
                title: thread.title,
                author: author.login,
                line: line,
                url: post.url,
                createdAt: post.createdAt
            )
        }
        return mentions.max { $0.createdAt < $1.createdAt }
    }

    /// The first line outside quotes that calls `login`. A login holds letters, digits and hyphens,
    /// so `@login-two` and `name@login` are someone else.
    static func mentionLine(of login: String, in body: String) -> String? {
        let pattern = "(?<![A-Za-z0-9_-])@\(NSRegularExpression.escapedPattern(for: login))(?![A-Za-z0-9-])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        return body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                !line.hasPrefix(">") && regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            }
    }

    public static func openInMacBrowser(log: HubLog) -> OpenURL {
        { url in
            Task {
                do {
                    _ = try await Subprocess.run(["/usr/bin/open", url], timeoutSeconds: timeoutSeconds)
                } catch {
                    log.write("could not open \(url): \(error)")
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

private func reviewText(_ pullRequest: PullRequest) -> String {
    if pullRequest.reviewDecision == "CHANGES_REQUESTED" { return "changes requested" }
    if !pullRequest.approvedBy.isEmpty { return "approved by \(pullRequest.approvedBy.joined(separator: ", "))" }
    return pullRequest.reviewDecision == "APPROVED" ? "approved" : "awaiting review"
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
            ? "\(checksText(pullRequest.checks)), \(reviewText(pullRequest))"
            : "review for \(pullRequest.author)",
        url: pullRequest.url,
        approvedBy: isMine ? pullRequest.approvedBy : nil
    )
}

/// Someone waits for an answer, so the light blinks yellow until the user opens or mutes the mention.
private func item(for mention: Mention) -> GithubItem {
    GithubItem(
        key: "mention-\(mention.id)",
        group: .mention,
        light: .waiting,
        title: String("#\(mention.number) \(mention.title)".prefix(120)),
        text: String("\(mention.author): \(mention.line)".prefix(200)),
        url: mention.url
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
    private let fetchMentions: FetchMentions
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
        fetchMentions: FetchMentions? = nil,
        openURL: OpenURL? = nil
    ) {
        self.store = store
        self.log = log
        self.fetch = fetch
        self.fetchMentions = fetchMentions ?? GithubCommands.fetchMentions(log: log)
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
        let fetch = fetch
        let fetchMentions = fetchMentions
        do {
            async let pullRequests = fetch()
            async let mentions = fetchMentions()
            // A newer mention in the same thread comes with a new key, so a muted one stays muted for good.
            latest = try await mentions.map { Entry(item: item(for: $0), fingerprint: "") }
                + pullRequests.map { Entry(item: item(for: $0), fingerprint: fingerprint($0)) }
        } catch {
            // Offline or an expired login must not switch off the lights already on screen.
            log.write("github sync failed: \(error)")
            return false
        }
        forgetOutdatedMutes()
        await publish()
        return true
    }

    /// Takes a key, not a URL, so the board can only open what GitHub reported. An opened mention is read.
    func open(key: String) async -> Bool {
        guard let entry = latest.first(where: { $0.item.key == key }) else { return false }
        openURL(entry.item.url)
        if entry.item.group == .mention { await mute(entry) }
        return true
    }

    func mute(key: String) async -> Bool {
        guard let entry = latest.first(where: { $0.item.key == key }) else { return false }
        await mute(entry)
        return true
    }

    private func mute(_ entry: Entry) async {
        muted[entry.item.key] = entry.fingerprint
        saveMutes()
        await publish()
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
            log.write("could not save muted GitHub rows: \(error)")
        }
    }
}
