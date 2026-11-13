import Foundation
import Testing
@testable import HubKit

private func session(pinned: String) -> String {
    let tabs = [
        #"{"id":"\#(pinned)","isPinned":true}"#,
        #"{"id":"plain","isPinned":false}"#,
        #"{"id":"terminal"}"#,
    ]
    return #"{"unifiedTabs":{"repo::/work":[\#(tabs.joined(separator: ","))]}}"#
}

private struct SavedState {
    let path: String

    init() async throws {
        path = FileManager.default.temporaryDirectory.appending(path: "orca-\(UUID().uuidString).db").path()
        try await run("create table profile_state_documents (domain text primary key, payload text, revision integer)")
    }

    private func run(_ statement: String) async throws {
        _ = try await Subprocess.run(["sqlite3", path, statement], timeoutSeconds: 5)
    }

    func save(_ payload: String, revision: Int) async throws {
        try await run(
            "insert or replace into profile_state_documents values ('workspaceSession', '\(payload)', \(revision))"
        )
    }
}

@Suite struct OrcaPinsTests {
    @Test func findsThePinnedTabs() async throws {
        let state = try await SavedState()
        try await state.save(session(pinned: "first"), revision: 1)
        #expect(await OrcaPins(path: state.path).tabs() == ["first"])
    }

    @Test func followsTheRevision() async throws {
        let state = try await SavedState()
        let pins = OrcaPins(path: state.path)
        try await state.save(session(pinned: "first"), revision: 1)
        #expect(await pins.tabs() == ["first"])
        try await state.save(session(pinned: "unread"), revision: 1)
        #expect(await pins.tabs() == ["first"])
        try await state.save(session(pinned: "second"), revision: 2)
        #expect(await pins.tabs() == ["second"])
    }

    @Test func keepsTheLastPinsWhenTheStateIsUnreadable() async throws {
        let state = try await SavedState()
        let pins = OrcaPins(path: state.path)
        try await state.save(session(pinned: "first"), revision: 1)
        #expect(await pins.tabs() == ["first"])
        try await state.save("not json", revision: 2)
        #expect(await pins.tabs() == ["first"])
    }

    @Test func aMissingStateMeansNoPins() async {
        #expect(await OrcaPins(path: "/nonexistent/profile-state.db").tabs().isEmpty)
    }
}
