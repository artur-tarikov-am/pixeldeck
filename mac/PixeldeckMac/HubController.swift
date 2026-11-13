import Foundation
import HubKit
import Observation
import ServiceManagement

enum HubState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var isServing: Bool { self == .running || self == .starting }

    var summary: String {
        switch self {
        case .stopped: "Hub stopped"
        case .starting: "Hub starting…"
        case .running: "Hub running"
        case .failed(let message): "Hub failed: \(message)"
        }
    }
}

@MainActor
@Observable
final class HubController {
    private static let retryDelay: Duration = .seconds(10)

    private(set) var state = HubState.stopped
    private(set) var integrations: [HubKit.Integration] = []
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    private let port = HubConfig.port
    private let dataDirectory = HubConfig.dataDirectory
    private var hub: Hub?
    private var logURL: URL?
    private var retry: Task<Void, Never>?

    init() {
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let log = HubLog(dataDirectory: dataDirectory)
            do {
                try ClaudePlugin.copy(from: Self.bundledPlugin, dataDirectory: dataDirectory)
            } catch {
                log.write("could not copy the Claude Code plugin: \(error)")
            }
            let hub = Hub(dataDirectory: dataDirectory, log: log)
            self.hub = hub
            logURL = log.url
            Task { await watchIntegrations(of: hub) }
            Task { await start() }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func watchIntegrations(of hub: Hub) async {
        for await integrations in await hub.store.watchIntegrations() {
            self.integrations = integrations
        }
    }

    func start() async {
        guard let hub, !state.isServing else { return }
        retry?.cancel()
        state = .starting
        do {
            _ = try await hub.start(port: port) { [weak self] message in
                Task { await self?.lostListener(message) }
            }
            state = .running
        } catch {
            hub.log.write("could not start: \(error)")
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        retry?.cancel()
        await hub?.stop()
        state = .stopped
    }

    private func lostListener(_ message: String) async {
        guard state == .running else { return }
        hub?.log.write("listener lost: \(message)")
        await hub?.stop()
        fail(message)
    }

    /// Stays red until the port comes back; sleep and network changes can take the listener away.
    private func fail(_ message: String) {
        state = .failed(message)
        retry = Task {
            guard (try? await Task.sleep(for: Self.retryDelay)) != nil else { return }
            retry = nil // start() cancels a pending retry, and this one is not pending any more.
            await start()
        }
    }

    var logFile: URL? { logURL }

    func setIntegration(_ id: IntegrationID, isOn: Bool) async {
        await hub?.setIntegration(id, isOn: isOn)
    }

    private static var bundledPlugin: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Resources/ClaudePlugin")
    }

    func connectClaude() async throws {
        try await ClaudePlugin.install(dataDirectory: dataDirectory)
        hub?.log.write("connected Claude Code")
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            hub?.log.write("could not change launch at login: \(error)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
