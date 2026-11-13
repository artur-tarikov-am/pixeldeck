import Foundation

/// The hooks and the MCP server reach Claude Code as a plugin that comes with the app. Claude Code reads a plugin
/// from a folder in place, so the app keeps a copy in the data folder: it survives moving and deleting the app.
public enum ClaudePlugin {
    private static let installTimeoutSeconds: Double = 120

    static func folder(dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "claude-plugin")
    }

    /// Runs at every launch, so an updated app updates the hooks of the sessions started after it.
    public static func copy(from bundled: URL, dataDirectory: URL) throws {
        let folder = folder(dataDirectory: dataDirectory)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.copyItem(at: bundled, to: folder)
    }

    /// Adds the plugin to the Claude Code settings of this user; installing it again changes nothing.
    public static func install(dataDirectory: URL) async throws {
        let marketplace = folder(dataDirectory: dataDirectory).path(percentEncoded: false)
        _ = try await Subprocess.run(
            ["claude", "plugin", "install", "pixeldeck", "--marketplace", marketplace],
            timeoutSeconds: installTimeoutSeconds
        )
    }
}
