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

    let controller: HubController
    @Bindable var calendar: MeetingCalendar
    @State private var claude = ClaudeConnection.notAsked

    var body: some View {
        Form {
            Section("Integrations") {
                ForEach(controller.integrations, id: \.id) { integration in
                    Toggle(isOn: Binding(
                        get: { integration.isOn },
                        set: { isOn in Task { await controller.setIntegration(integration.id, isOn: isOn) } }
                    )) {
                        Text(integration.id.name)
                        Text(integration.id.setupHint ?? integration.sentence)
                    }
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
            }

            Section("Claude Code") {
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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
}

private extension HubKit.Integration {
    /// The board writes the description in small letters; a sentence here.
    var sentence: String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
