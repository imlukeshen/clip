import CoreModel
import Foundation

/// The one description of how the asset grid is laid out.
///
/// Three things need to agree on it: the columns the grid renders, the frames
/// marquee selection hit-tests against, and the stride arrow keys move by. When
/// each carried its own copy of the numbers they drifted apart, and a marquee
/// drawn over a card could miss the card it visibly covered.
public enum AssetGridMetrics {
    public static let minimumCardWidth: CGFloat = 152
    public static let maximumCardWidth: CGFloat = 210
    public static let spacing: CGFloat = 14
    /// Width-to-height ratio of the preview tile. Every card gets the same
    /// tile regardless of the shape of the image inside it, so rows line up.
    public static let thumbnailAspectRatio: CGFloat = 1.6
    /// Height of the title and metadata block beneath the tile.
    public static let captionHeight: CGFloat = 58

    public static func columnCount(gridWidth: CGFloat) -> Int {
        let usable = max(gridWidth, 0)
        return max(1, Int((usable + spacing) / (minimumCardWidth + spacing)))
    }

    public static func cardWidth(gridWidth: CGFloat) -> CGFloat {
        let columns = columnCount(gridWidth: gridWidth)
        let available = max(gridWidth, 0) - CGFloat(columns - 1) * spacing
        return min(maximumCardWidth, max(available / CGFloat(columns), minimumCardWidth))
    }

    public static func cardHeight(gridWidth: CGFloat) -> CGFloat {
        cardWidth(gridWidth: gridWidth) / thumbnailAspectRatio + captionHeight
    }

    /// Frames for the cards in layout order, in the grid's own coordinates.
    public static func layout(of ids: [AssetID], gridWidth: CGFloat) -> GridLayout {
        let columns = columnCount(gridWidth: gridWidth)
        let width = cardWidth(gridWidth: gridWidth)
        let height = cardHeight(gridWidth: gridWidth)
        var frames: [AssetID: CGRect] = [:]
        for (index, id) in ids.enumerated() {
            frames[id] = CGRect(
                x: CGFloat(index % columns) * (width + spacing),
                y: CGFloat(index / columns) * (height + spacing),
                width: width,
                height: height
            )
        }
        return GridLayout(frames: frames)
    }
}
