import AppKit
import SwiftUI

/// The closed notch, which stays on screen all day. Redrawn through SwiftUI twelve times a second
/// it cost several percent of the CPU, so it draws into a layer on its own clock, and SwiftUI
/// only hears when the wings or the line of news under them change size.
struct WingsLayer: NSViewRepresentable {
    let model: DeckModel
    let bar: NotchBar
    let notch: NotchController

    func makeNSView(context: Context) -> WingsView {
        WingsView(model: model, bar: bar, notch: notch)
    }

    func updateNSView(_ view: WingsView, context: Context) {}
}

final class WingsView: NSView {
    /// How often a notch without wings checks whether there is something to show.
    private static let restingInterval: TimeInterval = 0.5

    private let model: DeckModel
    private let bar: NotchBar
    private let notch: NotchController
    private let pixels = CALayer()
    /// The picture in points: one cell to `Scene.feedPixel`.
    private var pictureSize = CGSize.zero
    private var clock: Task<Void, Never>?

    init(model: DeckModel, bar: NotchBar, notch: NotchController) {
        self.model = model
        self.bar = bar
        self.notch = notch
        super.init(frame: .zero)
        wantsLayer = true
        pixels.magnificationFilter = .nearest
        layer?.addSublayer(pixels)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("WingsView is only made in code")
    }

    override func viewDidMoveToWindow() {
        clock?.cancel()
        guard window != nil else { return }
        clock = Task { [weak self] in
            while let interval = self?.draw() {
                guard (try? await Task.sleep(for: .seconds(interval))) != nil else { return }
            }
        }
    }

    override func layout() {
        super.layout()
        place()
    }

    /// Returns when to draw again.
    private func draw() -> TimeInterval {
        let picture = bar.render(
            deck: model.deck, connection: model.connection, lastArrival: model.lastArrival, now: .now,
            notch: notch.geometry
        )
        if notch.wing != picture.wing { notch.wing = picture.wing }
        if notch.drop != picture.drop { notch.drop = picture.drop }
        pixels.contents = picture.image
        pictureSize = CGSize(
            width: CGFloat(picture.image?.width ?? 0) * Scene.feedPixel,
            height: CGFloat(picture.image?.height ?? 0) * Scene.feedPixel
        )
        place()
        return picture.image == nil ? Self.restingInterval : Scene.idleFrameInterval
    }

    /// Centred at the top while the shape around it grows.
    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pixels.frame = CGRect(
            x: (bounds.width - pictureSize.width) / 2,
            y: bounds.height - pictureSize.height,
            width: pictureSize.width,
            height: pictureSize.height
        )
        CATransaction.commit()
    }
}
