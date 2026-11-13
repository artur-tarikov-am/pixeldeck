import Foundation

/// A chat or an agent terminal in Orca, as the board sees it.
public struct OrcaChat: Sendable, Equatable {
    private static let structuredPrefix = "structured-agent-session-"

    var key: String
    var worktreeId: String
    var provider: String
    var title: String
    var project: String
    var light: Light
    var changedAt: Int64
    var isPinned = false

    /// The tab of Orca this chat or terminal lives in.
    var tab: String { String(key.prefix { $0 != ":" }) }

    /// Orca's own chat id; agents in terminals have none.
    var structuredSession: String? {
        guard key.hasPrefix(Self.structuredPrefix) else { return nil }
        return String(key.dropFirst(Self.structuredPrefix.count).prefix { $0 != ":" })
    }

    /// What the Claude hook reports from inside this chat or terminal.
    var agent: String { structuredSession ?? key }

    /// Scheduled runs are not work of the user, unless one of them needs an answer.
    var isShown: Bool { light == .waiting || title.firstMatch(of: /\ run \d+$/) == nil }
}

public typealias FetchChats = @Sendable () async throws -> [OrcaChat]
public typealias OpenChat = @Sendable (OrcaChat) async throws -> Void
public typealias CloseChat = @Sendable (OrcaChat) async throws -> Void

private struct WorktreeList: Decodable {
    struct MainAgent: Decodable {
        let outcome: String?
    }

    struct Agent: Decodable {
        private static let failedOutcomes: Set = ["failure", "interruption"]
        private static let unknownProvider = "agent"

        let paneKey: String
        let parentPaneKey: String?
        let agentType: String?
        let state: String
        let conversationName: String?
        let displayName: String?
        let taskTitle: String?
        let prompt: String?
        let stateStartedAt: Double?
        let mainAgent: MainAgent?

        var provider: String { agentType ?? Self.unknownProvider }

        var light: Light {
            switch state {
            case "working": .running
            case "blocked", "waiting": .waiting
            default: Self.failedOutcomes.contains(mainAgent?.outcome ?? "") ? .failed : .done
            }
        }
    }

    struct Worktree: Decodable {
        let worktreeId: String
        let repo: String
        let isActive: Bool?
        let agents: [Agent]?
    }

    let worktrees: [Worktree]

    var chats: [OrcaChat] {
        worktrees.flatMap { worktree in
            (worktree.agents ?? []).filter { $0.parentPaneKey == nil }.map { agent in
                OrcaChat(
                    key: agent.paneKey,
                    worktreeId: worktree.worktreeId,
                    provider: agent.provider,
                    title: String(
                        (agent.conversationName ?? agent.displayName ?? agent.taskTitle ?? agent.prompt ?? worktree.repo)
                            .prefix(120)
                    ),
                    project: worktree.repo,
                    light: agent.light,
                    changedAt: Int64(agent.stateStartedAt ?? 0)
                )
            }
        }
    }
}

public enum OrcaCommands {
    private static let bundleIdentifier = "com.stablyai.orca"
    private static let chatLimit = 200
    private static let openTimeoutSeconds: Double = 5
    private static let workspaceCheckInterval: Double = 0.05
    private static let workspaceChecks = 60
    private static let pins = OrcaPins()

    private struct Reveal: Decodable {
        struct Refusal: Decodable { let message: String }

        let ok: Bool
        let refusal: Refusal?
    }

    private struct TabClosure: Decodable {
        let refused: Bool?
        let refusalReason: String?
    }

    private struct Ignored: Decodable {}

    public static let fetchChats: FetchChats = {
        var chats = try await listWorktrees().chats
        let pinnedTabs = await pins.tabs()
        for index in chats.indices {
            chats[index].isPinned = pinnedTabs.contains(chats[index].tab)
        }
        return chats
    }

    private static func listWorktrees() async throws -> WorktreeList {
        try await OrcaRuntime.call("worktree.ps", ["limit": chatLimit], as: WorktreeList.self)
    }

    /// `worktree.activate` answers before the window has switched.
    private static func waitUntilShown(worktree worktreeId: String) async throws {
        for _ in 0..<workspaceChecks {
            let worktrees = try await listWorktrees().worktrees
            if worktrees.contains(where: { $0.worktreeId == worktreeId && $0.isActive == true }) { return }
            try await sleep(seconds: workspaceCheckInterval)
        }
        throw OrcaFailure(message: "Orca did not switch to the workspace")
    }

    /// Orca has two kinds of tab and no single call for both; neither brings the window forward.
    /// `agentSession.reveal` only creates a missing chat tab and reports a refusal: it leaves the Mac window alone,
    /// and that window ignores `session.tabs.activate` for a chat until the workspace of the chat is on screen.
    public static let openChat: OpenChat = { chat in
        let worktree = "id:\(chat.worktreeId)"
        _ = try await OrcaRuntime.call("worktree.activate", ["worktree": worktree], as: Ignored.self)
        if let session = chat.structuredSession {
            let reveal = try await OrcaRuntime.call("agentSession.reveal", ["sessionId": session], as: Reveal.self)
            if !reveal.ok { throw OrcaFailure(message: reveal.refusal?.message ?? "Orca refused to open the chat") }
            try await waitUntilShown(worktree: chat.worktreeId)
            let tab = ["worktree": worktree, "tabId": "agent-session:\(session)"]
            _ = try await OrcaRuntime.call("session.tabs.activate", tab, as: Ignored.self)
        } else {
            let pane = chat.key.split(separator: ":").map(String.init)
            var params = ["worktreeId": chat.worktreeId, "tabId": pane[0]]
            if pane.count > 1 { params["leafId"] = pane[1] }
            _ = try await OrcaRuntime.call("terminal.reveal", params, as: Ignored.self)
        }
        _ = try await Subprocess.run(["/usr/bin/open", "-b", bundleIdentifier], timeoutSeconds: openTimeoutSeconds)
    }

    /// `agentSession.close` stops the agent and takes the tab with it. A terminal goes with its whole tab,
    /// and that call answers `ok` even when it refuses.
    public static let closeChat: CloseChat = { chat in
        if let session = chat.structuredSession {
            _ = try await OrcaRuntime.call("agentSession.close", ["sessionId": session], as: Ignored.self)
        } else {
            let tab = ["worktree": "id:\(chat.worktreeId)", "tabId": chat.tab, "reason": "user"]
            let closure = try await OrcaRuntime.call("session.tabs.close", tab, as: TabClosure.self)
            if closure.refused == true {
                throw OrcaFailure(message: "Orca refused to close the tab: \(closure.refusalReason ?? "no reason given")")
            }
        }
    }
}

public actor OrcaWatcher {
    private static let pollInterval: Double = 3

    private let store: Store
    private let claude: ClaudeActivity
    private let log: HubLog
    private let now: @Sendable () -> Date
    private let fetch: FetchChats
    private let openChat: OpenChat
    private let closeChat: CloseChat
    private var latest: [OrcaChat] = []
    private var isReachable = true
    private var polling: Task<Void, Never>?

    public init(
        store: Store,
        claude: ClaudeActivity,
        log: HubLog,
        now: @escaping @Sendable () -> Date = { .now },
        fetch: @escaping FetchChats = OrcaCommands.fetchChats,
        openChat: @escaping OpenChat = OrcaCommands.openChat,
        closeChat: @escaping CloseChat = OrcaCommands.closeChat
    ) {
        self.store = store
        self.claude = claude
        self.log = log
        self.now = now
        self.fetch = fetch
        self.openChat = openChat
        self.closeChat = closeChat
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

    /// While Orca is off or silent the Claude tile shows the sessions inside it, so a failure only costs the names.
    /// Returns whether Orca answered.
    @discardableResult
    func sync() async -> Bool {
        var hasAnswered = false
        if await store.isOn(.orca) {
            hasAnswered = await poll()
        } else {
            latest = []
        }
        await claude.setOrcaReporting(hasAnswered)
        await store.setOrca(rows(questions: await claude.questionsInOrca))
        return hasAnswered
    }

    private func poll() async -> Bool {
        do {
            latest = try await fetch()
            if !isReachable { log.write("orca is back") }
            isReachable = true
        } catch {
            latest = []
            if isReachable { log.write("orca sync failed: \(error)") }
            isReachable = false
        }
        return isReachable
    }

    private func rows(questions: [String: String]) -> [OrcaSession] {
        let moment = now().timeIntervalSince1970
        let shown = latest.filter(\.isShown).sorted { $0.changedAt > $1.changedAt }.map { chat in
            OrcaSession(
                id: chat.key,
                provider: chat.provider,
                project: chat.project,
                title: chat.title,
                light: chat.light,
                question: questions[chat.agent],
                isCurrent: !chat.light.isFinished
                    || moment - Double(chat.changedAt) / 1000 < Light.finishedVisible,
                isPinned: chat.isPinned
            )
        }
        return Light.byAttention(shown) { $0.light }
    }

    /// Takes a key, so the board can only open what Orca reported.
    func open(key: String) async throws -> Bool {
        guard let chat = latest.first(where: { $0.key == key }) else { return false }
        try await openChat(chat)
        return true
    }

    /// Takes a key for the same reason as `open`. The list is updated before the answer, because the board waits for it.
    func close(key: String) async throws -> Bool {
        guard let chat = latest.first(where: { $0.key == key }) else { return false }
        try await closeChat(chat)
        await sync()
        return true
    }
}
