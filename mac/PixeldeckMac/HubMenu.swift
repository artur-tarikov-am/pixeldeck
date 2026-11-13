import AppKit
import SwiftUI

/// Opens with a right click on the notch: how the hub is doing, and the way to Settings.
struct HubMenu: View {
    let controller: HubController
    let calendar: MeetingCalendar

    var body: some View {
        Text(controller.state.summary)

        Divider()

        Button("Settings…") { SettingsWindow.show(controller: controller, calendar: calendar) }

        Divider()

        Button("Quit Pixeldeck") { NSApp.terminate(nil) }
    }
}
