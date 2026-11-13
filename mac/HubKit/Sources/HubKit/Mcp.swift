import Foundation

private let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]
private let methodNotFound = -32601
private let invalidRequest = -32600

/// JSON-RPC answered directly, without sessions, so a hub restart breaks no client.
/// The same five tools through the Swift MCP SDK would still need these schemas and add a dependency.
extension Hub {
    func respondToMcp(_ request: HTTPRequest, _ responder: HTTPResponder) async throws {
        guard request.method == "POST" else {
            return await responder.send(405, json: try encodeJSON(["error": "use POST"]), headers: [("allow", "POST")])
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) else {
            throw HTTPError(400, "body is not valid JSON")
        }
        guard let message = message as? [String: Any], let method = message["method"] as? String else {
            return await responder.send(400, json: try rpcError(id: nil, code: invalidRequest, "expected one request"))
        }
        guard let id = message["id"] else {
            return await responder.send(202)
        }
        let params = message["params"] as? [String: Any] ?? [:]

        let result: [String: Any]
        switch method {
        case "initialize":
            result = initializeResult(params)
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": mcpTools()]
        case "tools/call":
            result = await callTool(params)
        default:
            return await responder.send(200, json: try rpcError(id: id, code: methodNotFound, "Method not found"))
        }
        let answer: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        await responder.send(200, json: try JSONSerialization.data(withJSONObject: answer))
    }

    private func rpcError(id: Any?, code: Int, _ message: String) throws -> Data {
        let answer: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ]
        return try JSONSerialization.data(withJSONObject: answer)
    }

    private func initializeResult(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        return [
            "protocolVersion": requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? supportedProtocolVersions[0],
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": ["name": "pixeldeck", "version": "1.0.0"],
        ]
    }

    private func mcpTools() -> Any {
        (try? JSONSerialization.jsonObject(with: Data(mcpToolsJSON.utf8))) ?? []
    }

    private func callTool(_ params: [String: Any]) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = (try? JSONSerialization.data(withJSONObject: params["arguments"] ?? [String: Any]())) ?? Data("{}".utf8)
        do {
            return ["content": [["type": "text", "text": try await runTool(name, arguments)]]]
        } catch let error as HTTPError {
            return toolFailure(error.message)
        } catch {
            return toolFailure(String(describing: error))
        }
    }

    private func toolFailure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func runTool(_ name: String, _ arguments: Data) async throws -> String {
        switch name {
        case "show_card":
            let card = try decodeJSON(CardInput.self, from: arguments)
            let unknown = try actions.unknownRuns(in: card)
            if !unknown.isEmpty { throw HTTPError(400, "unknown actions: \(unknown.joined(separator: ", "))") }
            return text(try encodeJSON(["id": await store.upsert(card).id]))
        case "set_status":
            await store.setStatus(try decodeJSON(StatusInput.self, from: arguments))
            return "ok"
        case "ask":
            return try await ask(try decodeJSON(AskInput.self, from: arguments))
        case "remove_card":
            let id = try decodeJSON([String: String].self, from: arguments)["id"] ?? ""
            guard await store.remove(id) else { throw HTTPError(404, "card not found") }
            return "ok"
        case "list_cards":
            return text(try await encodeJSON(store.state.cards))
        default:
            throw HTTPError(404, "Tool \(name) not found")
        }
    }

    private func text(_ json: Data) -> String {
        String(decoding: json, as: UTF8.self)
    }

    private func ask(_ input: AskInput) async throws -> String {
        let card = await store.upsert(CardInput(
            title: input.question,
            text: input.details,
            sprite: .named("waiting"),
            actions: input.options.map(ActionInput.init(option:))
        ))
        let answer = await store.waitForAnswer(cardId: card.id, timeoutSeconds: input.timeoutSeconds)
        if answer == nil { await store.remove(card.id) }
        return answer ?? "no answer"
    }
}
