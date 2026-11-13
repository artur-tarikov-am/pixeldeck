import Foundation

public final class Hub: Sendable {
    public let store: Store
    public let log: HubLog
    let actions: Actions
    let claude: ClaudeActivity
    let orca: OrcaWatcher
    let github: GithubWatcher
    private let server = HTTPServer()

    public init(
        dataDirectory: URL,
        log: HubLog,
        isSetUp: IsSetUp = IntegrationID.isSetUpOnThisMac,
        fetchPullRequests: @escaping FetchPullRequests = GithubCommands.fetchPullRequests,
        openURL: OpenURL? = nil,
        fetchChats: @escaping FetchChats = OrcaCommands.fetchChats,
        openChat: @escaping OpenChat = OrcaCommands.openChat,
        closeChat: @escaping CloseChat = OrcaCommands.closeChat,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.log = log
        store = Store(dataDirectory: dataDirectory, log: log, isSetUp: isSetUp)
        actions = Actions(dataDirectory: dataDirectory)
        claude = ClaudeActivity(store: store, now: now)
        orca = OrcaWatcher(
            store: store, claude: claude, log: log, now: now, fetch: fetchChats, openChat: openChat, closeChat: closeChat
        )
        github = GithubWatcher(
            store: store, dataDirectory: dataDirectory, log: log, fetch: fetchPullRequests, openURL: openURL
        )
    }

    /// A hidden tile comes back with current data rather than empty until the next update.
    /// Orca syncs either way: without it the Claude sessions inside it move to the Claude tile.
    public func setIntegration(_ id: IntegrationID, isOn: Bool) async {
        await store.setIntegration(id, isOn: isOn)
        switch id {
        case .orca: await orca.sync()
        case .claude: await claude.publish()
        case .github: if isOn { await github.sync() }
        }
    }

    /// Listens on loopback; port 0 picks a free one. Returns the port the hub listens on.
    public func start(
        port: UInt16,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws -> UInt16 {
        let port = try await server.start(port: port, handler: { [self] in await respond(to: $0, with: $1) }, onFailure: onFailure)
        await claude.start()
        await orca.start()
        await github.start()
        log.write("hub is listening on port \(port)")
        return port
    }

    public func stop() async {
        await github.stop()
        await orca.stop()
        await claude.stop()
        await server.stop()
        log.write("hub stopped")
    }
}
