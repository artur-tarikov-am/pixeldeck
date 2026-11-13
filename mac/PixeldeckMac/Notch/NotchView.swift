import SwiftUI

/// The black shape around the notch. Closed it is the notch with the wings of `NotchBar`,
/// open it unfolds into the board.
struct NotchView: View {
    private static let unfold = Animation.spring(duration: 0.35, bounce: 0.15)

    let model: DeckModel
    let scene: Scene
    let gestures: DeckGestures
    let bar: NotchBar
    let notch: NotchController
    let hub: HubController
    let calendar: MeetingCalendar

    var body: some View {
        let size = notch.shapeSize
        ZStack(alignment: .top) {
            if notch.isOpen {
                TimelineView(.animation(minimumInterval: gestures.isMoving ? nil : Scene.idleFrameInterval)) {
                    board(at: $0.date)
                }
            } else {
                WingsLayer(model: model, bar: bar, notch: notch)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(.black)
        .clipShape(notch.isOpen
            ? NotchShape(ear: NotchLayout.openEar, radius: NotchLayout.openRadius)
            : NotchShape(ear: notch.wing > 0 ? NotchLayout.closedEar : 0, radius: NotchLayout.closedRadius))
        // Hidden behind the camera housing while there is nothing to show.
        .opacity(notch.isOpen || notch.wing > 0 ? 1 : 0)
        .animation(Self.unfold, value: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contextMenu { HubMenu(controller: hub, calendar: calendar) }
    }

    /// The board, laid out from its top left corner.
    @ViewBuilder
    private func board(at date: Date) -> some View {
        let geometry = notch.geometry
        let size = CGSize(width: NotchLayout.boardWidth, height: geometry.maxOpenHeight)
        let frame = scene.render(
            deck: model.deck, connection: model.connection, lastArrival: model.lastArrival, now: date,
            size: size, safeTop: geometry.height, safeBottom: NotchLayout.bottomInset
        )
        let height = min(size.height, scene.contentHeight ?? size.height)
        if let frame {
            FrameView(
                frame: frame,
                width: size.width,
                safeTop: geometry.height,
                swipeOffset: gestures.swipeOffset,
                pullOffset: gestures.pullOffset
            )
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gestures.changed(Drag($0)) }
                    .onEnded { gestures.ended(Drag($0), screenWidth: size.width) }
            )
            .onChange(of: height, initial: true) { notch.openHeight = height }
        }
    }
}

/// The notch drawn larger: the top corners curve outward into the edge of the screen,
/// the bottom ones are round.
nonisolated struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { (ear, radius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: ear, dy: 0)
        let radius = min(radius, body.width / 2, body.height - ear)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: rect.minY),
            tangent2End: CGPoint(x: body.minX, y: body.maxY),
            radius: ear
        )
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.maxY),
            tangent2End: CGPoint(x: body.maxX, y: body.maxY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.maxY),
            tangent2End: CGPoint(x: body.maxX, y: rect.minY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: ear
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
