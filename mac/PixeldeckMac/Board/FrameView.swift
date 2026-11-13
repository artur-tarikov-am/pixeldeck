import SwiftUI

/// Stacks the layers of one frame from the top left corner of the board. The content follows
/// a swipe or a pull, the header beside the notch stays put.
struct FrameView: View {
    let frame: Frame
    let width: CGFloat
    /// Where the safe area ends, so the pull indicator grows below the header.
    let safeTop: CGFloat
    let swipeOffset: CGFloat
    let pullOffset: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let backdrop = frame.backdrop {
                boardPixels(backdrop)
            }
            picture
                .offset(x: swipeOffset, y: pullOffset)
            if let indicator = frame.pullIndicator {
                pullIndicator(indicator)
            }
            if let header = frame.header {
                pixels(
                    header,
                    width: CGFloat(header.width) * Scene.feedPixel,
                    height: CGFloat(header.height) * Scene.feedPixel
                )
            }
        }
    }

    private var picture: some View {
        ZStack(alignment: .topLeading) {
            boardPixels(frame.board)
            if let feed = frame.feed {
                Color.clear
                    .frame(width: width, height: frame.feedHeight)
                    .overlay(alignment: .top) {
                        pixels(
                            feed,
                            width: CGFloat(feed.width) * Scene.feedPixel,
                            height: frame.feedLayerHeight
                        )
                        .offset(y: -frame.feedOffset)
                    }
                    .clipped()
                    .offset(y: frame.feedTop)
            }
        }
    }

    /// Grows from the top edge as the content moves away, so it never covers the header.
    private func pullIndicator(_ image: CGImage) -> some View {
        let indicatorWidth = CGFloat(image.width) * Scene.boardPixel
        let height = CGFloat(image.height) * Scene.boardPixel
        return Color.clear
            .frame(width: indicatorWidth, height: min(pullOffset, height), alignment: .top)
            .overlay(alignment: .top) {
                pixels(image, width: indicatorWidth, height: height)
            }
            .clipped()
            .offset(x: (width - indicatorWidth) / 2, y: safeTop)
    }

    private func boardPixels(_ image: CGImage) -> some View {
        pixels(
            image,
            width: CGFloat(image.width) * Scene.boardPixel,
            height: CGFloat(image.height) * Scene.boardPixel
        )
    }

    private func pixels(_ image: CGImage, width: CGFloat, height: CGFloat) -> some View {
        Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: width, height: height)
    }
}
