import Foundation

public enum HubConfig {
    public static var port: UInt16 {
        ProcessInfo.processInfo.environment["PIXELDECK_PORT"].flatMap(UInt16.init) ?? 7777
    }

    public static var dataDirectory: URL {
        ProcessInfo.processInfo.environment["PIXELDECK_DATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pixeldeck")
    }
}
