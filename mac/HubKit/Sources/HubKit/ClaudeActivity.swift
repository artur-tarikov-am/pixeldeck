import Foundation

public struct ClaudeEvent: Decodable, Sendable {
    var event: String
    var session: String
    var cwd: String?
    var notification: String?
    var tool: String?
    var question: String?
    var orca: String?
}

/// Keeps one light per Claude Code session. Sessions inside Orca are its chats, so they only show while it is silent.
public actor ClaudeActivity {
    private static let activityExpiry: TimeInterval = 30 * 60
    private static let refreshInterval: Double = 15
    private static let questionTool = "AskUserQuestion"
    private static let questionLength = 120

    private struct Tracked {
        var session: ClaudeSession
        var seenAt: Date
        var orcaAgent: String?
    }

    private let store: Store
    private let now: @Sendable () -> Date
    private var sessions: [Tracked] = []
    private var isOrcaReporting = false
    private var refresher: Task<Void, Never>?

    public init(store: Store, now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.now = now
    }

    func start() {
        refresher = Task {
            while (try? await sleep(seconds: Self.refreshInterval)) != nil {
                await publish()
            }
        }
    }

    func stop() {
        refresher?.cancel()
    }

    func setOrcaReporting(_ isReporting: Bool) async {
        guard isReporting != isOrcaReporting else { return }
        isOrcaReporting = isReporting
        await publish()
    }

    /// Orca does not report what its chats ask, so the hooks do, keyed by the agent in Orca.
    var questionsInOrca: [String: String] {
        let asked = sessions.compactMap { tracked in
            tracked.session.question.flatMap { question in tracked.orcaAgent.map { ($0, question) } }
        }
        return Dictionary(asked) { first, _ in first }
    }

    func handle(_ event: ClaudeEvent) async {
        if event.event == "UserPromptSubmit" {
            begin(event)
            return await publish()
        }

        guard let index = sessions.firstIndex(where: { $0.session.id == event.session }) else { return }
        sessions[index].seenAt = now()

        switch event.event {
        case "PreToolUse":
            if event.tool == Self.questionTool, let question = event.question, !question.isEmpty {
                sessions[index].session.light = .waiting
                sessions[index].session.question = String(question.prefix(Self.questionLength))
            }
        case "PostToolUse":
            sessions[index].session.light = .running
            sessions[index].session.question = nil
        case "Notification":
            if event.notification == "permission_prompt" { sessions[index].session.light = .waiting }
        case "Stop":
            finish(index, light: .done)
        case "StopFailure":
            finish(index, light: .failed)
        case "SessionEnd":
            sessions.remove(at: index)
        default:
            break
        }
        await publish()
    }

    private func begin(_ event: ClaudeEvent) {
        let moment = now()
        let cwd = event.cwd ?? ""
        let tracked = Tracked(
            session: ClaudeSession(
                id: event.session,
                project: cwd.isEmpty ? "claude" : (cwd as NSString).lastPathComponent,
                light: .running,
                startedAt: Int64(moment.timeIntervalSince1970 * 1000)
            ),
            seenAt: moment,
            orcaAgent: event.orca
        )
        if let index = sessions.firstIndex(where: { $0.session.id == event.session }) {
            sessions[index] = tracked
        } else {
            sessions.append(tracked)
        }
    }

    private func finish(_ index: Int, light: Light) {
        sessions[index].session.light = light
        sessions[index].session.question = nil
    }

    func publish() async {
        forgetStale()
        let shown = sessions.filter { !isOrcaReporting || $0.orcaAgent == nil }.map(\.session)
        await store.setClaude(Light.byAttention(shown) { $0.light })
    }

    /// A crashed session never sends Stop, so a silent one stops counting after a while.
    private func forgetStale() {
        let moment = now()
        sessions.removeAll { tracked in
            let limit = tracked.session.light.isFinished ? Light.finishedVisible : Self.activityExpiry
            return moment.timeIntervalSince(tracked.seenAt) > limit
        }
    }
}
