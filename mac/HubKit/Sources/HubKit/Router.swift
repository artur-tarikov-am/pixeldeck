import Foundation

private let heartbeatSeconds: Double = 15
private let defaultAnswerTimeoutSeconds: Double = 60
private let maxAnswerTimeoutSeconds: Double = 3600

func encodeJSON<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return try encoder.encode(value)
}

func decodeJSON<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch let error as ValidationError {
        throw HTTPError(400, error.description)
    } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
        throw HTTPError(400, "body is not valid JSON")
    } catch DecodingError.keyNotFound(let key, _) {
        throw HTTPError(400, "\(key.stringValue) is required")
    } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context) {
        throw HTTPError(400, "\(fieldName(context)) has the wrong type")
    } catch DecodingError.dataCorrupted(let context) {
        throw HTTPError(400, "\(fieldName(context)) has a wrong value")
    }
}

private func fieldName(_ context: DecodingError.Context) -> String {
    context.codingPath.last?.stringValue ?? "body"
}

extension Hub {
    func respond(to request: HTTPRequest, with responder: HTTPResponder) async {
        do {
            try await route(request, responder)
        } catch let error as HTTPError {
            await responder.send(error.status, json: try? encodeJSON(["error": error.message]))
        } catch is CancellationError {
            return
        } catch {
            log.write("request failed: \(error)")
            await responder.send(500, json: try? encodeJSON(["error": "internal error"]))
        }
    }

    private func route(_ request: HTTPRequest, _ responder: HTTPResponder) async throws {
        let segments = request.path.split(separator: "/").map(String.init)
        let id = segments.count > 1 ? segments[1] : ""
        let endpoint = "\(request.method) /\(segments.first ?? "")"
            + (segments.count > 1 ? "/:id" : "")
            + (segments.count > 2 ? "/\(segments[2])" : "")

        if endpoint == "GET /health" {
            return await responder.send(200, json: try encodeJSON(["ok": true]))
        }

        // Browsers attach Origin to cross-site requests; without this check any web page
        // open on this Mac could reach the hub and press buttons.
        if request.headers["origin"] != nil { throw HTTPError(403, "browser requests are not allowed") }

        if segments.first == "mcp" { return try await respondToMcp(request, responder) }

        switch endpoint {
        case "GET /stream":
            await stream(responder)
        case "GET /cards":
            await responder.send(200, json: try await encodeJSON(store.state.cards))
        case "POST /cards":
            let card = try decodeJSON(CardInput.self, from: request.body)
            let unknown = try actions.unknownRuns(in: card)
            if !unknown.isEmpty { throw HTTPError(400, "unknown actions: \(unknown.joined(separator: ", "))") }
            await responder.send(201, json: try await encodeJSON(store.upsert(card)))
        case "POST /claude-events":
            await claude.handle(try decodeJSON(ClaudeEvent.self, from: request.body))
            await responder.send(204)
        case "POST /orca-opens":
            let input = try decodeJSON(KeyInput.self, from: request.body)
            guard try await orca.open(key: input.key) else { throw HTTPError(404, "chat not found") }
            await responder.send(204)
        case "POST /orca-closes":
            let input = try decodeJSON(KeyInput.self, from: request.body)
            guard try await orca.close(key: input.key) else { throw HTTPError(404, "chat not found") }
            await responder.send(204)
        case "POST /orca-refreshes":
            guard await orca.sync() else { throw HTTPError(502, "Orca did not answer") }
            await responder.send(204)
        case "POST /github-refreshes":
            guard await github.sync() else { throw HTTPError(502, "GitHub did not answer") }
            await responder.send(204)
        case "POST /github-mutes":
            let input = try decodeJSON(KeyInput.self, from: request.body)
            guard await github.mute(key: input.key) else { throw HTTPError(404, "pull request not found") }
            await responder.send(204)
        case "POST /github-opens":
            let input = try decodeJSON(KeyInput.self, from: request.body)
            guard await github.open(key: input.key) else { throw HTTPError(404, "pull request not found") }
            await responder.send(204)
        case "PUT /integrations/:id":
            guard let integration = IntegrationID(rawValue: id) else { throw HTTPError(404, "integration not found") }
            let input = try decodeJSON(IntegrationInput.self, from: request.body)
            await setIntegration(integration, isOn: input.isOn)
            await responder.send(204)
        case "PUT /status":
            await store.setStatus(try decodeJSON(StatusInput.self, from: request.body))
            await responder.send(204)
        case "DELETE /cards/:id":
            guard await store.remove(id) else { throw HTTPError(404, "card not found") }
            await responder.send(204)
        case "POST /cards/:id/press":
            let input = try decodeJSON(PressInput.self, from: request.body)
            guard await actions.press(store: store, cardId: id, index: input.index) else {
                throw HTTPError(404, "action not found")
            }
            await responder.send(202)
        case "GET /cards/:id/answer":
            let requested = request.query["timeout"].flatMap(Double.init) ?? defaultAnswerTimeoutSeconds
            let seconds = requested.isNaN ? defaultAnswerTimeoutSeconds : min(requested, maxAnswerTimeoutSeconds)
            let answer = await store.waitForAnswer(cardId: id, timeoutSeconds: seconds)
            await responder.send(200, json: try encodeJSON(Answer(answer: answer)))
        default:
            throw HTTPError(404, "no such endpoint")
        }
    }

    private struct Answer: Encodable {
        let answer: String?

        private enum CodingKeys: String, CodingKey {
            case answer
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(answer, forKey: .answer)
        }
    }

    private func stream(_ responder: HTTPResponder) async {
        await responder.beginEventStream()
        let updates = await store.subscribe()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in updates {
                    guard let json = try? encodeJSON(state) else { continue }
                    await responder.sendEvent(Data("data: ".utf8) + json + Data("\n\n".utf8))
                }
            }
            group.addTask {
                while (try? await sleep(seconds: heartbeatSeconds)) != nil {
                    await responder.sendEvent(Data(": ping\n\n".utf8))
                }
            }
        }
    }
}
