import AppKit

/// Where the notch is, in screen coordinates: the camera housing of a MacBook,
/// or a stand-in of the same size in the middle of the menu bar on other screens.
struct NotchGeometry: Equatable {
    private static let standInWidth: CGFloat = 185
    private static let maxOpenHeight: CGFloat = 600
    private static let maxOpenShare: CGFloat = 0.6

    let midX: CGFloat
    let top: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// The open notch scrolls past this.
    let maxOpenHeight: CGFloat

    init(screen: NSScreen) {
        let frame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = right.minX - left.maxX
            midX = left.maxX + width / 2
            height = screen.safeAreaInsets.top
        } else {
            width = Self.standInWidth
            midX = frame.midX
            height = NSStatusBar.system.thickness
        }
        top = frame.maxY
        maxOpenHeight = min(Self.maxOpenHeight, (frame.height * Self.maxOpenShare).rounded())
    }

    /// The screen with the camera housing, or else the one with the menu bar.
    static func current() -> NotchGeometry? {
        let screen = NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.screens.first
        return screen.map(NotchGeometry.init)
    }

    /// A shape of this size hanging from the top of the screen at the notch.
    func frame(of size: CGSize) -> CGRect {
        CGRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}

/// Sizes of the shape around the notch, in points.
enum NotchLayout {
    /// 228 cells of the board and 304 of the feed across.
    static let boardWidth: CGFloat = 456
    /// Keeps the last card clear of the round bottom corners.
    static let bottomInset: CGFloat = 12
    static let openEar: CGFloat = 10
    static let openRadius: CGFloat = 22
    static let closedEar: CGFloat = 6
    static let closedRadius: CGFloat = 10
    static let openWidth = boardWidth + 2 * openEar
}
