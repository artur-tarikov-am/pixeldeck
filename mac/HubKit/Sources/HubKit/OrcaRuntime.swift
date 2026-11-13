import Foundation

struct OrcaFailure: Error {
    let message: String
}

/// A client for the socket the `orca` command talks to: one JSON line each way.
/// The API is internal to Orca, so everything that depends on it stays in `Orca.swift` and here.
enum OrcaRuntime {
    private static let timeoutSeconds = 5
    private static let readChunk = 1 << 16

    /// Rewritten on every launch of Orca, with a new socket and a new token.
    private struct Descriptor: Decodable {
        struct Transport: Decodable {
            let kind: String
            let endpoint: String
        }

        let transports: [Transport]
        let authToken: String
    }

    private struct Request<Params: Encodable>: Encodable {
        let id: String
        let authToken: String
        let method: String
        let params: Params
    }

    private struct Reply<Answer: Decodable>: Decodable {
        struct Failure: Decodable {
            let code: String
            let message: String
        }

        let ok: Bool
        let result: Answer?
        let error: Failure?
    }

    private struct Keepalive: Decodable {
        let _keepalive: Bool
    }

    /// Orca keeps it from the first launch on.
    static var userData: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/orca")
    }

    static var hasRun: Bool {
        FileManager.default.fileExists(atPath: userData.path(percentEncoded: false))
    }

    private static var descriptorURL: URL {
        userData.appending(path: "orca-runtime.json")
    }

    static func call<Params: Encodable & Sendable, Answer: Decodable>(
        _ method: String,
        _ params: Params,
        as type: Answer.Type
    ) async throws -> Answer {
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: descriptorURL))
        guard let socket = descriptor.transports.first(where: { $0.kind == "unix" }) else {
            throw OrcaFailure(message: "Orca offers no local socket")
        }
        let request = Request(id: UUID().uuidString, authToken: descriptor.authToken, method: method, params: params)
        let line = try JSONEncoder().encode(request) + Data("\n".utf8)

        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try exchange(line, path: socket.endpoint) })
            }
        }
        let decoded = try JSONDecoder().decode(Reply<Answer>.self, from: reply)
        guard decoded.ok, let result = decoded.result else {
            throw OrcaFailure(message: decoded.error.map { "\($0.code): \($0.message)" } ?? "Orca sent no result")
        }
        return result
    }

    /// Blocks until Orca answers, so it runs off the concurrency pool.
    private static func exchange(_ line: Data, path: String) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw OrcaFailure(message: "no socket") }
        defer { close(descriptor) }
        try configure(descriptor)
        try connect(descriptor, to: path)

        var unsent = line[...]
        while !unsent.isEmpty {
            let sent = unsent.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
            guard sent > 0 else { throw OrcaFailure(message: "could not write to Orca") }
            unsent = unsent.dropFirst(sent)
        }
        return try readReply(from: descriptor)
    }

    private static func configure(_ descriptor: Int32) throws {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        // A write to a closed socket must fail, not kill the hub with SIGPIPE.
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw OrcaFailure(message: "could not configure the socket") }
    }

    private static func connect(_ descriptor: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw OrcaFailure(message: "the socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw OrcaFailure(message: "Orca is not running") }
    }

    private static func readReply(from descriptor: Int32) throws -> Data {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: readChunk)
        while true {
            let count = recv(descriptor, &chunk, chunk.count, 0)
            guard count > 0 else { throw OrcaFailure(message: "Orca closed the connection") }
            received.append(contentsOf: chunk[..<count])
            while let end = received.firstIndex(of: UInt8(ascii: "\n")) {
                let line = received[received.startIndex..<end]
                received = Data(received[received.index(after: end)...])
                if !line.isEmpty, (try? JSONDecoder().decode(Keepalive.self, from: line)) == nil { return Data(line) }
            }
        }
    }
}
