import Foundation
import Testing
@testable import HubKit

private final class Chats: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [OrcaChat] = []
    private var isDown = false
    private var openedKeys: [String] = []
    private var closureRefused = false

    var list: [OrcaChat] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var down: Bool {
        get { lock.withLock { isDown } }
        set { lock.withLock { isDown = newValue } }
    }

    var refusesToClose: Bool {
        get { lock.withLock { closureRefused } }
        set { lock.withLock { closureRefused = newValue } }
    }

    var opened: [String] { lock.withLock { openedKeys } }

    func fetch() throws -> [OrcaChat] {
        if down { throw OrcaFailure(message: "Orca is not running") }
        return list
    }

    func open(_ chat: OrcaChat) {
        lock.withLock { openedKeys.append(chat.key) }
    }

    func close(_ chat: OrcaChat) throws {
        if refusesToClose { throw OrcaFailure(message: "refused") }
        list.removeAll { $0.key == chat.key }
    }
}

private func chat(
    _ session: String,
    _ light: Light,
    title: String = "Chat",
    changedAt: Int64 = 0,
    provider: String = "claude"
) -> OrcaChat {
    OrcaChat(
        key: "structured-agent-session-\(session):pane",
        worktreeId: "repo::/work",
        provider: provider,
        title: title,
        project: "repo",
        light: light,
        changedAt: changedAt
    )
}

private func makeHub(_ chats: Chats, now: @escaping @Sendable () -> Date = { .now }) async throws -> TestHub {
    try await TestHub(
        fetchChats: { try chats.fetch() },
        openChat: { chats.open($0) },
        closeChat: { try chats.close($0) },
        now: now
    )
}

private func millis(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
}

private func prompt(_ session: String, orca: String) -> String {
    #"{"event":"UserPromptSubmit","session":"\#(session)","cwd":"/work/deck","orca":"\#(orca)"}"#
}

private func promptOutsideOrca(_ session: String) -> String {
    #"{"event":"UserPromptSubmit","session":"\#(session)","cwd":"/work/deck"}"#
}

@Suite struct OrcaTests {
    @Test func readsTheSessionOutOfThePaneKey() {
        #expect(chat("claude_1", .running).agent == "claude_1")
        var terminal = chat("x", .running)
        terminal.key = "tab:leaf"
        #expect(terminal.structuredSession == nil)
        #expect(terminal.agent == "tab:leaf")
        #expect(terminal.tab == "tab")
        #expect(chat("claude_1", .running).tab == "structured-agent-session-claude_1")
    }

    @Test func aPinDoesNotChangeTheOrderOfTheTile() async throws {
        let chats = Chats()
        var pinned = chat("a", .done, title: "Pinned")
        pinned.isPinned = true
        chats.list = [pinned, chat("b", .waiting, title: "Ask")]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        let sessions = await test.store.state.orca
        #expect(sessions.map(\.title) == ["Ask", "Pinned"])
        #expect(sessions.map(\.isPinned) == [false, true])
    }

    @Test func putsChatsThatNeedAnAnswerFirstAndNamesThem() async throws {
        let chats = Chats()
        chats.list = [chat("a", .done, title: "Old"), chat("b", .running, title: "Now"), chat("c", .waiting, title: "Ask")]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        #expect(await test.store.state.orca.map(\.title) == ["Ask", "Now", "Old"])
    }

    @Test func oldFinishedChatsStopBeingCurrentButStayInTheList() async throws {
        let moment = Date()
        let chats = Chats()
        chats.list = [
            chat("a", .done, title: "Just now", changedAt: millis(moment.addingTimeInterval(-60))),
            chat("b", .done, title: "Yesterday", changedAt: millis(moment.addingTimeInterval(-86400))),
        ]
        let test = try await makeHub(chats, now: { moment })
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        let sessions = await test.store.state.orca
        #expect(sessions.count == 2)
        #expect(sessions.filter(\.isCurrent).map(\.title) == ["Just now"])
    }

    @Test func hidesScheduledRunsUnlessTheyWait() async throws {
        let chats = Chats()
        chats.list = [chat("a", .running, title: "tg-digest run 3438"), chat("b", .waiting, title: "ops-help run 7")]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        #expect(await test.store.state.orca.map(\.title) == ["ops-help run 7"])
    }

    @Test func aHookSessionInOrcaShowsOnceWithItsQuestion() async throws {
        let chats = Chats()
        chats.list = [chat("claude_1", .waiting, title: "Named")]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        _ = try await test.post("/claude-events", prompt("hook-id", orca: "claude_1"))
        _ = try await test.post(
            "/claude-events",
            #"{"event":"PreToolUse","session":"hook-id","tool":"AskUserQuestion","question":"Ship it?"}"#
        )
        await test.hub.orca.sync()
        let sessions = await test.store.state.orca
        #expect(sessions.map(\.title) == ["Named"])
        #expect(sessions.first?.question == "Ship it?")
        #expect(await test.store.state.claude.isEmpty)
    }

    @Test func sessionsOutsideOrcaGoToTheirOwnTile() async throws {
        let chats = Chats()
        chats.list = [chat("claude_1", .running)]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        _ = try await test.post("/claude-events", promptOutsideOrca("terminal"))
        await test.hub.orca.sync()
        #expect(await test.store.state.orca.map(\.project) == ["repo"])
        #expect(await test.store.state.claude.map(\.project) == ["deck"])
    }

    @Test func aNewChatStaysOffTheClaudeTileBeforeOrcaReportsIt() async throws {
        let chats = Chats()
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        _ = try await test.post("/claude-events", prompt("hook-id", orca: "claude_new"))
        #expect(await test.store.state.claude.isEmpty)
    }

    @Test func aChatOfAnotherProviderIsAChatLikeAnyOther() async throws {
        let chats = Chats()
        chats.list = [chat("codex_1", .waiting, title: "Named", provider: "codex")]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        #expect(await test.store.state.orca.map(\.provider) == ["codex"])
        #expect(await test.store.state.status.mood == .waiting)
    }

    @Test func oldFinishedChatsLeaveTheCharacterAlone() async throws {
        let moment = Date()
        let chats = Chats()
        chats.list = [chat("a", .failed, changedAt: millis(moment.addingTimeInterval(-86400)))]
        let test = try await makeHub(chats, now: { moment })
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        #expect(await test.store.state.status.mood == .idle)
    }

    @Test func fallsBackToTheHooksWhenOrcaIsGone() async throws {
        let chats = Chats()
        chats.list = [chat("claude_1", .running, title: "Named")]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        _ = try await test.post("/claude-events", prompt("hook-id", orca: "claude_1"))
        await test.hub.orca.sync()
        #expect(await test.store.state.orca.map(\.title) == ["Named"])
        #expect(await test.store.state.claude.isEmpty)
        chats.down = true
        await test.hub.orca.sync()
        #expect(await test.store.state.orca.isEmpty)
        #expect(await test.store.state.claude.map(\.project) == ["deck"])
    }

    @Test func opensOnlyWhatOrcaReported() async throws {
        let chats = Chats()
        let known = chat("claude_1", .done)
        chats.list = [known]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        #expect(try await test.post("/orca-opens", #"{"key":"\#(known.key)"}"#) == 204)
        #expect(chats.opened == [known.key])
        #expect(try await test.post("/orca-opens", #"{"key":"anything"}"#) == 404)
        #expect(chats.opened == [known.key])
    }

    @Test func closesOnlyWhatOrcaReportedAndUpdatesTheList() async throws {
        let chats = Chats()
        let known = chat("claude_1", .done)
        chats.list = [known]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        #expect(try await test.post("/orca-closes", #"{"key":"anything"}"#) == 404)
        #expect(await test.store.state.orca.count == 1)
        #expect(try await test.post("/orca-closes", #"{"key":"\#(known.key)"}"#) == 204)
        #expect(await test.store.state.orca.isEmpty)
    }

    @Test func aClosedChatDoesNotComeBackThroughTheHooks() async throws {
        let chats = Chats()
        let known = chat("claude_1", .running)
        chats.list = [known]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        _ = try await test.post("/claude-events", prompt("hook-id", orca: "claude_1"))
        await test.hub.orca.sync()
        #expect(try await test.post("/orca-closes", #"{"key":"\#(known.key)"}"#) == 204)
        #expect(await test.store.state.orca.isEmpty)
        #expect(await test.store.state.claude.isEmpty)
    }

    @Test func aRefusedCloseKeepsTheChat() async throws {
        let chats = Chats()
        let known = chat("claude_1", .done)
        chats.list = [known]
        chats.refusesToClose = true
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.orca.sync()
        #expect(try await test.post("/orca-closes", #"{"key":"\#(known.key)"}"#) == 500)
        #expect(await test.store.state.orca.count == 1)
    }

    @Test func aRefreshReportsWhetherOrcaAnswered() async throws {
        let chats = Chats()
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        chats.list = [chat("a", .running, title: "New")]
        #expect(try await test.send("POST", "/orca-refreshes").status == 204)
        #expect(await test.store.state.orca.map(\.title) == ["New"])

        chats.down = true
        #expect(try await test.send("POST", "/orca-refreshes").status == 502)
    }

    @Test func aSwitchedOffTileDoesNotAskOrca() async throws {
        let chats = Chats()
        chats.list = [chat("claude_1", .running)]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.setIntegration(.orca, isOn: false)
        #expect(await test.hub.orca.sync() == false)
        #expect(await test.store.state.orca.isEmpty)
    }

    @Test func switchingOrcaOffMovesItsClaudeSessionsToTheClaudeTile() async throws {
        let chats = Chats()
        chats.list = [chat("claude_1", .running)]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        _ = try await test.post("/claude-events", prompt("hook-id", orca: "claude_1"))
        await test.hub.orca.sync()
        await test.hub.setIntegration(.orca, isOn: false)
        #expect(await test.store.state.orca.isEmpty)
        #expect(await test.store.state.claude.map(\.project) == ["deck"])
        await test.hub.setIntegration(.orca, isOn: true)
        #expect(await test.store.state.orca.map(\.project) == ["repo"])
        #expect(await test.store.state.claude.isEmpty)
    }

    @Test func aSwitchedOffClaudeTileLeavesTheChatsInOrca() async throws {
        let chats = Chats()
        chats.list = [chat("claude_1", .running)]
        let test = try await makeHub(chats)
        defer { Task { await test.stop() } }
        await test.hub.setIntegration(.claude, isOn: false)
        await test.hub.orca.sync()
        #expect(await test.store.state.orca.count == 1)
    }
}
