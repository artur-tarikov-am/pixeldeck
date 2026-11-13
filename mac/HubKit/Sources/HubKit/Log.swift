import Foundation

public final class HubLog: Sendable {
    private static let maxBytes = 1_000_000

    public let url: URL
    private let queue = DispatchQueue(label: "pixeldeck.log")

    public init(dataDirectory: URL) {
        url = dataDirectory.appending(path: "hub.log")
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > Self.maxBytes { try? FileManager.default.removeItem(at: url) }
    }

    public func write(_ message: String) {
        let line = "\(Date.now.ISO8601Format()) \(message)\n"
        queue.async { [url] in
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let file = try? FileHandle(forWritingTo: url) else { return }
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: Data(line.utf8))
        }
    }
}
