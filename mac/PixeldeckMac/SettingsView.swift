import AppKit
import HubKit
import SwiftUI

/// The app has no windows of its own, so Settings gets one when asked for.
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(controller: HubController, calendar: MeetingCalendar) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(controller: controller, calendar: calendar)
            ))
            window.title = "Pixeldeck Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    private enum ClaudeConnection: Equatable {
        case notAsked, connecting, connected, failed(String)
    }

    private static let calendarPrivacy = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )

    private static let leaveChoices = [0, 15, 30, 45, 60, 180, 300, 600, 1800]
    /// All sections together are taller than a laptop screen, so the form scrolls.
    private static let height: CGFloat = 720

    let controller: HubController
    @Bindable var calendar: MeetingCalendar
    @State private var claude = ClaudeConnection.notAsked
    @AppStorage(CharacterPresence.secondsKey) private var leavesAfter = CharacterPresence.defaultSeconds

    var body: some View {
        Form {
            ForEach(controller.integrations, id: \.id) { integration in
                Section(integration.id.name) {
                    Toggle(isOn: Binding(
                        get: { integration.isOn },
                        set: { isOn in Task { await controller.setIntegration(integration.id, isOn: isOn) } }
                    )) {
                        Text("On the board")
                        Text(integration.id.setupHint ?? integration.sentence)
                    }
                    NewsPicker(source: integration.id.newsSource)
                        .disabled(!integration.isOn)
                    if integration.id == .claude { claudePlugin }
                }
            }

            Section("Calendar") {
                switch calendar.access {
                case .granted:
                    Toggle(isOn: $calendar.isOn) {
                        Text("Meetings in the notch")
                        Text(calendar.isOn ? meetingsNote : Self.meetingsHint)
                    }
                case .notAsked:
                    LabeledContent {
                        Button("Allow…") { Task { await calendar.requestAccess() } }
                    } label: {
                        Text("Meetings in the notch")
                        Text("\(Self.meetingsHint) Reads the Calendar app of this Mac.")
                    }
                case .denied:
                    LabeledContent {
                        Button("Open Privacy") {
                            if let url = Self.calendarPrivacy { NSWorkspace.shared.open(url) }
                        }
                    } label: {
                        Text("Meetings in the notch")
                        Text("Pixeldeck has no access to the Calendar. Allow it in Privacy & Security → Calendars.")
                    }
                }
                if calendar.access == .granted {
                    NewsPicker(source: .meetings)
                        .disabled(!calendar.isOn)
                }
            }

            Section("Notch") {
                Picker(selection: $leavesAfter) {
                    ForEach(Self.leaveChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "After \(Duration.seconds(seconds).formatted(.units(width: .abbreviated)))")
                            .tag(seconds)
                    }
                } label: {
                    Text("Character leaves")
                    Text("When the wings show the same for this long. Anything new brings it back.")
                }
            }

            Section("Hub") {
                LabeledContent {
                    if controller.state.isServing {
                        Button("Stop") { Task { await controller.stop() } }
                    } else {
                        Button("Start") { Task { await controller.start() } }
                    }
                } label: {
                    Text(controller.state.summary)
                    Text("Serves the notch and Claude Code on 127.0.0.1:\(String(HubConfig.port)).")
                }
                LabeledContent("Log") {
                    Button("Open") {
                        if let log = controller.logFile { NSWorkspace.shared.open(log) }
                    }
                }
                Toggle("Launch at Login", isOn: Binding(
                    get: { controller.launchesAtLogin },
                    set: { controller.setLaunchesAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: Self.height)
    }

    private var claudePlugin: some View {
        LabeledContent {
            switch claude {
            case .connecting: ProgressView().controlSize(.small)
            case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .notAsked, .failed: Button("Connect") { Task { await connectClaude() } }
            }
        } label: {
            Text("Pixeldeck plugin")
            Text(claudeNote)
        }
    }

    private static let meetingsHint = "Today's meetings with a countdown and a link to join."

    /// Says what the calendar gave, so a missing account shows here rather than as an empty notch.
    private var meetingsNote: String {
        let left = calendar.meetings.filter { $0.end > .now }
        guard let next = left.first else { return "No more meetings today." }
        let time = next.start.formatted(date: .omitted, time: .shortened)
        return "\(left.count) left today, next \(next.title) at \(time)."
    }

    private var claudeNote: String {
        switch claude {
        case .notAsked, .connecting: "Sessions show on the board and get the Pixeldeck tools. Needs claude in Terminal."
        case .connected: "Connected. Sessions started from now on show on the board."
        case .failed(let message): "Could not connect: \(message)"
        }
    }

    private func connectClaude() async {
        claude = .connecting
        do {
            try await controller.connectClaude()
            claude = .connected
        } catch {
            claude = .failed(error.localizedDescription)
        }
    }
}

private extension IntegrationID {
    var name: String {
        switch self {
        case .orca: "Orca"
        case .claude: "Claude Code"
        case .github: "GitHub"
        }
    }

    /// Why the tile would stay empty on this Mac.
    var setupHint: String? {
        guard !Self.isSetUpOnThisMac(self) else { return nil }
        return switch self {
        case .orca: "Orca has not run on this Mac yet."
        case .claude: nil
        case .github: "Needs gh auth login in Terminal."
        }
    }

    var newsSource: NewsSource {
        switch self {
        case .orca: .orca
        case .claude: .claude
        case .github: .github
        }
    }
}

/// Whether a source notifies at all, and whether its notifications stay on the board.
private struct NewsPicker: View {
    let source: NewsSource
    @AppStorage private var mode: NewsMode

    init(source: NewsSource) {
        self.source = source
        _mode = AppStorage(wrappedValue: .standard, source.modeKey)
    }

    var body: some View {
        Picker(selection: $mode) {
            Text("Off").tag(NewsMode.off)
            Text("Show").tag(NewsMode.shown)
            Text("Show and keep").tag(NewsMode.kept)
        } label: {
            Text("Notifications")
            Text([source.events, mode.outcome].compactMap { $0 }.joined(separator: " "))
        }
    }
}

private extension NewsSource {
    var events: String {
        switch self {
        case .orca: "When a chat waits for you, finishes or fails."
        case .claude: "When a session waits for you, finishes or fails."
        case .github: "Mentions, approvals, and your pull requests turning ready to merge, failing CI or getting changes requested."
        case .meetings: "Five minutes before a meeting and as it starts."
        }
    }
}

private extension NewsMode {
    var outcome: String? {
        switch self {
        case .off: nil
        case .shown: "A line under the notch for three seconds."
        case .kept: "A line under the notch, then a row on the board until you clear it."
        }
    }
}

private extension HubKit.Integration {
    /// The board writes the description in small letters; a sentence here.
    var sentence: String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
