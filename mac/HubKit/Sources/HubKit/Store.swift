import Foundation

public actor Store {
    private static let maxCards = 50
    private static let agentMoodLifetime: Double = 30 * 60

    /// What survives a restart. `integrations` is missing from files written before the catalog.
    private struct SavedDeck: Decodable {
        var cards: [Card]
        var github: [GithubItem]
        var integrations: [Integration]?
    }

    private let url: URL
    private let log: HubLog
    public private(set) var state: DeckState
    private var answers: [String: String] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<String?, Never>]] = [:]
    private var streams: [UUID: AsyncStream<DeckState>.Continuation] = [:]
    private var integrationWatchers: [UUID: AsyncStream<[Integration]>.Continuation] = [:]
    private var statusReset: Task<Void, Never>?
    private var publishedAgentMood = Mood.idle

    public init(dataDirectory: URL, log: HubLog, isSetUp: IsSetUp) {
        url = dataDirectory.appending(path: "state.json")
        self.log = log
        state = Self.load(from: url, log: log, integrations: Integration.defaults(isSetUp: isSetUp))
    }

    func card(_ id: String) -> Card? {
        state.cards.first { $0.id == id }
    }

    /// What the notch listens to: the current state first, then every change.
    func subscribe() -> AsyncStream<DeckState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: DeckState.self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(state)
        streams[id] = continuation
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        streams[id] = nil
    }

    /// What the Settings window shows: the integrations now, then after every switch.
    public func watchIntegrations() -> AsyncStream<[Integration]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [Integration].self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatchingIntegrations(id) }
        }
        continuation.yield(state.integrations)
        integrationWatchers[id] = continuation
        return stream
    }

    private func stopWatchingIntegrations(_ id: UUID) {
        integrationWatchers[id] = nil
    }

    func upsert(_ input: CardInput) -> Card {
        let previous = input.key.flatMap { key in state.cards.first { $0.key == key } }
        let card = Card(
            id: previous?.id ?? UUID().uuidString.lowercased(),
            key: input.key,
            title: input.title,
            text: input.text,
            sprite: input.sprite,
            createdAt: Date.now.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true)),
            actions: input.actions.map {
                CardAction(label: $0.label, url: $0.url, run: $0.run, args: $0.args, reply: $0.reply, state: .idle)
            }
        )
        let others = state.cards.filter { $0.id != card.id }
        state.cards = Array(([card] + others).prefix(Self.maxCards))
        changed()
        return card
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        guard card(id) != nil else { return false }
        state.cards.removeAll { $0.id == id }
        settleWaiters(cardId: id, answer: nil)
        changed()
        return true
    }

    enum PressOutcome {
        case notFound, handled
        case run(name: String, args: [String])
    }

    /// Checks and claims the action in one step, so a double click cannot start a run twice.
    func press(cardId: String, index: Int) -> PressOutcome {
        guard let cardIndex = state.cards.firstIndex(where: { $0.id == cardId }),
              state.cards[cardIndex].actions.indices.contains(index)
        else { return .notFound }

        let action = state.cards[cardIndex].actions[index]
        if let reply = action.reply {
            answer(cardId: cardId, reply: reply)
        }
        guard let name = action.run, action.state != .running else { return .handled }
        setActionState(cardId: cardId, index: index, state: .running)
        return .run(name: name, args: action.args ?? [])
    }

    private func answer(cardId: String, reply: String) {
        answers[cardId] = reply
        settleWaiters(cardId: cardId, answer: reply)
        remove(cardId)
    }

    func setActionState(cardId: String, index: Int, state actionState: ActionState, note: String? = nil) {
        guard let cardIndex = state.cards.firstIndex(where: { $0.id == cardId }),
              state.cards[cardIndex].actions.indices.contains(index)
        else { return }
        state.cards[cardIndex].actions[index].state = actionState
        state.cards[cardIndex].note = note
        changed()
    }

    func setStatus(_ input: StatusInput) {
        statusReset?.cancel()
        statusReset = nil
        state.status = Status(mood: input.mood, text: input.text)
        if input.mood != .idle {
            statusReset = Task { [ttlSeconds = input.ttlSeconds] in
                guard (try? await sleep(seconds: ttlSeconds)) != nil else { return }
                self.resetStatus()
            }
        }
        changed()
    }

    private func resetStatus() {
        state.status = .idle
        changed()
    }

    func setOrca(_ sessions: [OrcaSession]) {
        let shown = isOn(.orca) ? sessions : []
        guard state.orca != shown else { return }
        state.orca = shown
        agentsChanged()
    }

    func setClaude(_ sessions: [ClaudeSession]) {
        let shown = isOn(.claude) ? sessions : []
        guard state.claude != shown else { return }
        state.claude = shown
        agentsChanged()
    }

    /// Only a change of mood is published, so a status set by a script is not overwritten.
    private func agentsChanged() {
        changed()
        let moodNow = agentMood
        guard moodNow != publishedAgentMood else { return }
        publishedAgentMood = moodNow
        setStatus(StatusInput(mood: moodNow, ttlSeconds: Self.agentMoodLifetime))
    }

    private var agentMood: Mood {
        let lights = state.orca.filter(\.isCurrent).map(\.light) + state.claude.map(\.light)
        if lights.contains(.waiting) { return .waiting }
        if lights.contains(.running) { return .thinking }
        if lights.contains(.failed) { return .error }
        return lights.contains(.done) ? .done : .idle
    }

    func setGithub(_ items: [GithubItem]) {
        let shown = isOn(.github) ? items : []
        guard state.github != shown else { return }
        state.github = shown
        changed()
    }

    func isOn(_ id: IntegrationID) -> Bool {
        state.integrations.contains { $0.id == id && $0.isOn }
    }

    func setIntegration(_ id: IntegrationID, isOn: Bool) {
        guard let index = state.integrations.firstIndex(where: { $0.id == id }) else { return }
        state.integrations[index].isOn = isOn
        if !isOn {
            switch id {
            case .orca: state.orca = []
            case .claude: state.claude = []
            case .github: state.github = []
            }
        }
        agentsChanged()
        for watcher in integrationWatchers.values { watcher.yield(state.integrations) }
    }

    /// The reply, or nil if the card is dismissed, the time runs out or the caller goes away.
    func waitForAnswer(cardId: String, timeoutSeconds: Double) async -> String? {
        if let ready = answers.removeValue(forKey: cardId) { return ready }
        guard card(cardId) != nil else { return nil }

        let waiter = UUID()
        let timeout = Task {
            guard (try? await sleep(seconds: timeoutSeconds)) != nil else { return }
            self.settle(cardId: cardId, waiter: waiter, answer: nil)
        }
        defer { timeout.cancel() }

        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[cardId, default: [:]][waiter] = continuation
            }
        } onCancel: {
            Task { await self.settle(cardId: cardId, waiter: waiter, answer: nil) }
        }
        if answer != nil { answers[cardId] = nil }
        return answer
    }

    private func settle(cardId: String, waiter: UUID, answer: String?) {
        waiters[cardId]?.removeValue(forKey: waiter)?.resume(returning: answer)
    }

    private func settleWaiters(cardId: String, answer: String?) {
        for continuation in (waiters.removeValue(forKey: cardId) ?? [:]).values {
            continuation.resume(returning: answer)
        }
    }

    private func changed() {
        save()
        for stream in streams.values { stream.yield(state) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            log.write("could not save state: \(error)")
        }
    }

    /// `integrations` are what a new board starts with; a saved choice wins.
    private static func load(from url: URL, log: HubLog, integrations: [Integration]) -> DeckState {
        var state = DeckState()
        state.integrations = integrations
        guard FileManager.default.fileExists(atPath: url.path) else { return state }
        do {
            let saved = try JSONDecoder().decode(SavedDeck.self, from: Data(contentsOf: url))
            state.github = saved.github
            state.integrations = integrations.map { entry in
                var entry = entry
                entry.isOn = saved.integrations?.first { $0.id == entry.id }?.isOn ?? entry.isOn
                return entry
            }
            state.cards = saved.cards.map { card in
                var card = card
                for index in card.actions.indices where card.actions[index].state == .running {
                    card.actions[index].state = .idle
                }
                return card
            }
            return state
        } catch {
            log.write("state.json is unreadable, kept as state.json.corrupt: \(error)")
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            return state
        }
    }
}
