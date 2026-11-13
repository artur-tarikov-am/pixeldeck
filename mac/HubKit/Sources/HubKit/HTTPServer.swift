import Foundation
import Network

public struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

public struct HTTPError: Error {
    let status: Int
    let message: String

    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

private enum StatusLine {
    static func reason(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        default: "Status"
        }
    }

    static func head(_ status: Int, _ headers: [(String, String)]) -> Data {
        let lines = ["HTTP/1.1 \(status) \(reason(status))"]
            + (headers + [("connection", "close")]).map { "\($0): \($1)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

/// Every connection carries one request, so there is no keep-alive to get wrong.
public final class HTTPResponder: Sendable {
    private let connection: NWConnection

    fileprivate init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ status: Int, json body: Data? = nil, headers: [(String, String)] = []) async {
        var all = headers
        if status != 204, status != 202 || body != nil {
            all.append(("content-type", "application/json"))
            all.append(("content-length", String(body?.count ?? 0)))
        }
        await write(StatusLine.head(status, all) + (body ?? Data()))
    }

    func beginEventStream() async {
        await write(StatusLine.head(200, [
            ("content-type", "text/event-stream"),
            ("cache-control", "no-store"),
            ("transfer-encoding", "chunked"),
        ]))
    }

    func sendEvent(_ text: Data) async {
        await write(Data(String(text.count, radix: 16).utf8) + Data("\r\n".utf8) + text + Data("\r\n".utf8))
    }

    fileprivate func write(_ data: Data) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}

public typealias HTTPHandler = @Sendable (HTTPRequest, HTTPResponder) async -> Void

private final class HTTPConnection: Sendable {
    private static let maxHeadBytes = 16_384
    private static let maxBodyBytes = 1_000_000
    private static let headEnd = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let responder: HTTPResponder

    init(connection: NWConnection) {
        self.connection = connection
        responder = HTTPResponder(connection: connection)
    }

    func cancel() {
        connection.cancel()
    }

    func serve(on queue: DispatchQueue, handler: @escaping HTTPHandler) async {
        connection.start(queue: queue)
        defer { connection.cancel() }

        let request: HTTPRequest
        do {
            request = try await readRequest()
        } catch let error as HTTPError {
            return await responder.send(error.status, json: Data("{\"error\":\"\(error.message)\"}".utf8))
        } catch {
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await handler(request, self.responder) }
            group.addTask { await self.waitForClientToLeave() }
            await group.next()
            connection.cancel()
            group.cancelAll()
        }
    }

    private func receive() async throws -> (data: Data?, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func waitForClientToLeave() async {
        while let (_, isComplete) = try? await receive(), !isComplete {}
    }

    private func readRequest() async throws -> HTTPRequest {
        var buffer = Data()
        while buffer.range(of: Self.headEnd) == nil {
            guard buffer.count <= Self.maxHeadBytes else { throw HTTPError(431, "headers too large") }
            buffer.append(try await nextChunk())
        }
        guard let headEnd = buffer.range(of: Self.headEnd) else { throw HTTPError(400, "bad request") }

        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), let target = URLComponents(string: String(parts[1])) else {
            throw HTTPError(400, "bad request")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPError(400, "bad header") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[line[..<colon].lowercased()] = value
        }
        guard headers["transfer-encoding"] == nil else { throw HTTPError(411, "content-length is required") }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            throw HTTPError(400, "bad content-length")
        }
        guard length <= Self.maxBodyBytes else { throw HTTPError(413, "body too large") }

        var body = Data(buffer[headEnd.upperBound...])
        if headers["expect"]?.lowercased() == "100-continue", body.count < length {
            await responder.write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        while body.count < length {
            body.append(try await nextChunk())
        }

        return HTTPRequest(
            method: String(parts[0]),
            path: target.path,
            query: Dictionary((target.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { _, last in last },
            headers: headers,
            body: body.prefix(length)
        )
    }

    private func nextChunk() async throws -> Data {
        let (data, isComplete) = try await receive()
        if let data, !data.isEmpty { return data }
        if isComplete { throw CancellationError() }
        return Data()
    }
}

public actor HTTPServer {
    private let queue = DispatchQueue(label: "pixeldeck.http")
    private var listener: NWListener?
    private var monitor: Task<Void, Never>?
    private var connections: [UUID: HTTPConnection] = [:]

    public init() {}

    /// Returns once the port is really bound; port 0 picks a free one. `onFailure` reports a later loss of the listener.
    public func start(
        port: UInt16,
        handler: @escaping HTTPHandler,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws -> UInt16 {
        let listener = try Self.makeListener(port: port)
        let (states, continuation) = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { continuation.yield($0) }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            Task { await self.accept(connection, handler: handler) }
        }
        listener.start(queue: queue)

        do {
            try await waitUntilReady(states)
        } catch {
            listener.cancel()
            throw error
        }
        self.listener = listener
        monitor = Task {
            for await state in states {
                switch state {
                case .failed(let error), .waiting(let error):
                    onFailure(error.localizedDescription)
                case .cancelled:
                    return
                default:
                    continue
                }
            }
        }
        return listener.port?.rawValue ?? 0
    }

    private func waitUntilReady(_ states: AsyncStream<NWListener.State>) async throws {
        for await state in states {
            switch state {
            case .ready:
                return
            case .failed(let error), .waiting(let error):
                throw error
            default:
                continue
            }
        }
        // The stream only ends early when the caller was cancelled.
        throw CancellationError()
    }

    /// Only this Mac reaches the hub, so the firewall does not ask about it.
    private static func makeListener(port: UInt16) throws -> NWListener {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw HTTPError(500, "bad port") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        return try NWListener(using: parameters)
    }

    private func accept(_ connection: NWConnection, handler: @escaping HTTPHandler) {
        let id = UUID()
        let served = HTTPConnection(connection: connection)
        connections[id] = served
        Task {
            await served.serve(on: queue, handler: handler)
            finished(id)
        }
    }

    private func finished(_ id: UUID) {
        connections[id] = nil
    }

    /// Drops every client too: the notch on the stream sees offline at once.
    public func stop() async {
        listener?.cancel()
        listener = nil
        await monitor?.value
        monitor = nil
        for connection in connections.values { connection.cancel() }
    }
}
