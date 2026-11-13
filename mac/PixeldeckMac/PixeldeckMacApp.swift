import AppKit
import HubKit

/// The hub, and the board it feeds in the notch of this Mac.
@main
final class PixeldeckMacApp: NSObject, NSApplicationDelegate {
    private var hub: HubController?
    private var calendar: MeetingCalendar?
    private var notch: NotchController?
    /// A background app is the first thing macOS naps: a napping hub misses its heartbeat, and the notch opens late.
    private var appNapBlocker: NSObjectProtocol?

    static func main() {
        let app = NSApplication.shared
        let delegate = PixeldeckMacApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appNapBlocker = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Serving the hub and watching the pointer at the notch"
        )
        let hub = HubController()
        self.hub = hub
        guard let geometry = NotchGeometry.current() else { return }
        let model = DeckModel(port: Int(HubConfig.port))
        let scene = Scene()
        // Meetings go straight to the notch: the hub never has them.
        let calendar = MeetingCalendar { scene.meetings = $0 }
        self.calendar = calendar
        notch = NotchController(model: model, scene: scene, geometry: geometry, hub: hub, calendar: calendar)
        Task { await model.run() }
    }
}
