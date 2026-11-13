import AppKit
import SwiftUI

/// Opens the notch while the pointer rests on it and closes it once the pointer leaves,
/// and tells the closed notch what happens on the board meanwhile.
/// The panel stays the size of the open notch; outside the shape it lets every click through.
@MainActor
@Observable
final class NotchController {
    private static let openDelay: Duration = .milliseconds(120)
    private static let closeDelay: Duration = .milliseconds(350)

    private(set) var isOpen = false
    private(set) var geometry: NotchGeometry
    /// Points each wing adds beside the closed notch, 0 while there is nothing to show. Set by `WingsView`.
    var wing: CGFloat = 0
    /// Points the line of news adds under the closed notch, 0 without news. Set by `WingsView`.
    var drop: CGFloat = 0
    /// How tall the board wants the open notch, as of its last frame.
    var openHeight: CGFloat = 0
    @ObservationIgnored private let gestures: DeckGestures
    @ObservationIgnored private let trackpad = TrackpadDrags()
    @ObservationIgnored private let news = NotchNews()
    @ObservationIgnored private let panel = NotchPanel()
    @ObservationIgnored private var pendingChange: (isOpen: Bool, task: Task<Void, Never>)?
    @ObservationIgnored private var monitors: [Any] = []

    /// Where the shape is heading; the pointer counts as inside only there.
    var shapeSize: CGSize {
        if isOpen { return CGSize(width: NotchLayout.openWidth, height: max(openHeight, geometry.height)) }
        let ear = wing > 0 ? NotchLayout.closedEar : 0
        return CGSize(width: geometry.width + 2 * (wing + ear), height: geometry.height + drop)
    }

    init(model: DeckModel, scene: Scene, geometry: NotchGeometry, hub: HubController, calendar: MeetingCalendar) {
        self.geometry = geometry
        let gestures = DeckGestures(model: model, scene: scene)
        self.gestures = gestures
        let bar = NotchBar(scene: scene, news: news)
        panel.contentView = FirstClickHostingView(rootView: NotchView(
            model: model, scene: scene, gestures: gestures, bar: bar, notch: self, hub: hub, calendar: calendar
        ))
        // The open notch shows the board itself.
        model.onChange = { [weak self] old, new in
            guard let self, !isOpen else { return }
            news.hear(old: old, new: new)
        }
        place()
        panel.orderFrontRegardless()
        watchPointer()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func screensChanged() {
        guard let current = NotchGeometry.current(), current != geometry else { return }
        geometry = current
        place()
    }

    /// Wide enough for the open notch and the widest wings, as tall as the open notch gets.
    private func place() {
        let size = CGSize(width: NotchLayout.openWidth, height: geometry.maxOpenHeight)
        panel.setFrame(geometry.frame(of: size), display: true)
    }

    private func watchPointer() {
        let pointer: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        // Moves go to the app in front, so this one mostly hears them through the global monitor.
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: pointer) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            },
            NSEvent.addLocalMonitorForEvents(matching: pointer) { [weak self] event in
                MainActor.assumeIsolated { self?.pointerMoved() }
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let isTaken = MainActor.assumeIsolated { self?.take(scroll: event) ?? false }
                return isTaken ? nil : event
            },
        ].compactMap { $0 }
    }

    private func pointerMoved() {
        // The pointer stops one point short of the top edge.
        let isInside = geometry.frame(of: shapeSize).insetBy(dx: 0, dy: -1).contains(NSEvent.mouseLocation)
        let isDragging = NSEvent.pressedMouseButtons & 1 != 0
        panel.ignoresMouseEvents = !isInside && !(isOpen && isDragging)
        if isInside {
            change(toOpen: true)
        } else if !isDragging {
            change(toOpen: false)
        }
    }

    /// Waits a moment first, so a pointer passing by on its way to the menu bar does not open the notch.
    private func change(toOpen wanted: Bool) {
        if wanted == isOpen {
            pendingChange?.task.cancel()
            pendingChange = nil
            return
        }
        guard pendingChange?.isOpen != wanted else { return }
        pendingChange?.task.cancel()
        let task = Task {
            guard (try? await Task.sleep(for: wanted ? Self.openDelay : Self.closeDelay)) != nil else { return }
            pendingChange = nil
            isOpen = wanted
            if wanted { news.clear() }
        }
        pendingChange = (wanted, task)
    }

    /// Returns whether the scroll was over the open notch.
    private func take(scroll event: NSEvent) -> Bool {
        guard isOpen, event.window === panel else { return false }
        let location = event.locationInWindow
        let point = CGPoint(x: location.x - NotchLayout.openEar, y: panel.frame.height - location.y)
        trackpad.handle(event, at: point, gestures: gestures, boardWidth: NotchLayout.boardWidth)
        return true
    }
}

/// A borderless, see-through panel over the menu bar that never takes focus from the app in front.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar and its icons.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on the panel of a background app has to act at once.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
