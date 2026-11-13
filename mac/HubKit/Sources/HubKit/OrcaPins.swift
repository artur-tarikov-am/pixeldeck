import Foundation
import SQLite3

/// Which tabs are pinned in the Orca window. The socket does not report that, so it is read from the state
/// the window saves, a few seconds late. The format is internal to Orca, like the socket.
actor OrcaPins {
    private struct WorkspaceSession: Decodable {
        struct Tab: Decodable {
            let id: String
            let isPinned: Bool?
        }

        let unifiedTabs: [String: [Tab]]
    }

    private static let revisionQuery = "select revision from profile_state_documents where domain = 'workspaceSession'"
    private static let sessionQuery = "select payload from profile_state_documents where domain = 'workspaceSession'"

    static var defaultPath: String {
        OrcaRuntime.userData.appending(path: "profiles/local-default/profile-state.db").path(percentEncoded: false)
    }

    private let path: String
    private var readRevision: Int64?
    private var pinned: Set<String> = []

    init(path: String = OrcaPins.defaultPath) {
        self.path = path
    }

    /// The session is parsed only when it changed. A pin is a detail, so if the state cannot be read
    /// the last known pins stay and the chats still come through.
    func tabs() -> Set<String> {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let revision = Self.value(of: Self.revisionQuery, in: database, read: { sqlite3_column_int64($0, 0) }),
              revision != readRevision,
              let payload = Self.value(of: Self.sessionQuery, in: database, read: Self.text),
              let session = try? JSONDecoder().decode(WorkspaceSession.self, from: payload)
        else { return pinned }

        readRevision = revision
        pinned = Set(session.unifiedTabs.values.joined().filter { $0.isPinned == true }.map(\.id))
        return pinned
    }

    private static func value<Value>(
        of query: String,
        in database: OpaquePointer?,
        read: (OpaquePointer?) -> Value?
    ) -> Value? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else { return nil }
        return read(statement)
    }

    private static func text(of statement: OpaquePointer?) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}
