import Foundation
import Testing
@testable import HubKit

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private func event(_ name: String, _ session: String, _ extra: String = "") -> String {
    #"{"event":"\#(name)","session":"\#(session)"\#(extra)}"#
}

private func start(_ test: TestHub, _ session: String) async throws {
    let status = try await test.post(
        "/claude-events",
        event("UserPromptSubmit", session, #","cwd":"/work/\#(session)-project""#)
    )
    #expect(status == 204)
}

private func send(_ test: TestHub, _ name: String, _ session: String, _ extra: String = "") async throws {
    _ = try await test.post("/claude-events", event(name, session, extra))
}

private func lights(_ test: TestHub) async -> [String] {
    await test.store.state.claude.map { "\($0.project):\($0.light.rawValue)" }
}

@Suite struct ClaudeLights {
    @Test func givesEverySessionItsOwnLightNamedAfterTheProject() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        try await start(test, "a")
        try await start(test, "b")
        try await send(test, "Stop", "a")
        #expect(await lights(test) == ["b-project:running", "a-project:done"])
        #expect(await test.store.state.status.mood == .thinking)
    }

    @Test func waitsForAPermissionAnswerAndResumesAfterTheToolRan() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        try await start(test, "a")
        try await send(test, "Notification", "a", #","notification":"permission_prompt""#)
        #expect(await lights(test) == ["a-project:waiting"])
        #expect(await test.store.state.status.mood == .waiting)
        try await send(test, "PostToolUse", "a", #","tool":"Bash""#)
        #expect(await lights(test) == ["a-project:running"])
    }

    @Test func doesNotTreatTheIdleReminderAfterStopAsWaiting() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        try await start(test, "a")
        try await send(test, "Stop", "a")
        try await send(test, "Notification", "a", #","notification":"idle_prompt""#)
        #expect(await lights(test) == ["a-project:done"])
    }

    @Test func showsAQuestionOnTheSessionUntilItIsAnswered() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        try await start(test, "a")
        try await send(test, "PreToolUse", "a", #","tool":"AskUserQuestion","question":"Ship it?""#)
        #expect(await test.store.state.claude[0].question == "Ship it?")
        try await send(test, "PostToolUse", "a", #","tool":"AskUserQuestion""#)
        #expect(await test.store.state.claude[0].question == nil)
    }

    @Test func removesTheLightWhenTheSessionEnds() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        try await start(test, "a")
        try await send(test, "SessionEnd", "a")
        #expect(await lights(test) == [])
        #expect(await test.store.state.status.mood == .idle)
    }

    @Test func finishedSessionsStayForTwoMinutes() async throws {
        let clock = Clock()
        let test = try await TestHub(now: { clock.now })
        defer { Task { await test.stop() } }
        try await start(test, "a")
        try await send(test, "Stop", "a")
        clock.advance(by: 119)
        await test.hub.claude.publish()
        #expect(await lights(test) == ["a-project:done"])
        clock.advance(by: 2)
        await test.hub.claude.publish()
        #expect(await lights(test) == [])
    }

    @Test func silentSessionsAreForgottenAfterThirtyMinutes() async throws {
        let clock = Clock()
        let test = try await TestHub(now: { clock.now })
        defer { Task { await test.stop() } }
        try await start(test, "a")
        clock.advance(by: 29 * 60)
        await test.hub.claude.publish()
        #expect(await lights(test) == ["a-project:running"])
        clock.advance(by: 2 * 60)
        await test.hub.claude.publish()
        #expect(await lights(test) == [])
    }

    @Test func leavesAStatusFromAScriptAloneUntilTheMoodChanges() async throws {
        let test = try await TestHub()
        defer { Task { await test.stop() } }
        try await start(test, "a")
        #expect(try await test.send("PUT", "/status", body: #"{"mood":"done","text":"from script"}"#).status == 204)
        try await send(test, "PostToolUse", "a", #","tool":"Bash""#)
        #expect(await test.store.state.status.text == "from script")
    }
}
