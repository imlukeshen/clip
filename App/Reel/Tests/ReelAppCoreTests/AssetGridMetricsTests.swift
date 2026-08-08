import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Asset grid metrics")
struct AssetGridMetricsTests {
    private func ids(_ count: Int) -> [AssetID] {
        (0..<count).map { AssetID(rawValue: "asset-\($0)") }
    }

    @Test("Cards and gaps fill the grid without overflowing it")
    func cardsFitTheGridWidth() {
        for gridWidth in stride(from: 160.0, through: 2_000.0, by: 1.0) {
            let columns = AssetGridMetrics.columnCount(gridWidth: gridWidth)
            let width = AssetGridMetrics.cardWidth(gridWidth: gridWidth)
            let used = CGFloat(columns) * width + CGFloat(columns - 1) * AssetGridMetrics.spacing
            #expect(columns >= 1)
            #expect(width >= AssetGridMetrics.minimumCardWidth)
            #expect(width <= AssetGridMetrics.maximumCardWidth)
            // A row may be narrower than the grid once cards hit their maximum,
            // but it must never be wider than the space it is given.
            #expect(used <= gridWidth + 0.001)
        }
    }

    /// The marquee rectangle is drawn in the same coordinates these frames use,
    /// so a card the marquee visibly covers has to be a card it selects.
    @Test("Frames match the columns and gaps the grid renders")
    func framesFollowTheRenderedGrid() {
        let gridWidth: CGFloat = 900
        let layout = AssetGridMetrics.layout(of: ids(7), gridWidth: gridWidth)
        let columns = AssetGridMetrics.columnCount(gridWidth: gridWidth)
        let width = AssetGridMetrics.cardWidth(gridWidth: gridWidth)
        let height = AssetGridMetrics.cardHeight(gridWidth: gridWidth)

        let first = layout.frames[AssetID(rawValue: "asset-0")]
        #expect(first == CGRect(x: 0, y: 0, width: width, height: height))

        let second = layout.frames[AssetID(rawValue: "asset-1")]
        #expect(second?.minX == width + AssetGridMetrics.spacing)
        #expect(second?.minY == 0)

        let wrapped = layout.frames[AssetID(rawValue: "asset-\(columns)")]
        #expect(wrapped?.minX == 0)
        #expect(wrapped?.minY == height + AssetGridMetrics.spacing)
    }

    @Test("Every card is the same size whatever it previews")
    func everyCardIsTheSameSize() {
        let layout = AssetGridMetrics.layout(of: ids(12), gridWidth: 740)
        let sizes = Set(layout.frames.values.map { "\($0.width)x\($0.height)" })
        #expect(sizes.count == 1)
    }

    @Test("A grid narrower than one card still lays out one column")
    func degenerateWidthKeepsOneColumn() {
        #expect(AssetGridMetrics.columnCount(gridWidth: 0) == 1)
        #expect(AssetGridMetrics.columnCount(gridWidth: -50) == 1)
        #expect(AssetGridMetrics.cardWidth(gridWidth: 0) == AssetGridMetrics.minimumCardWidth)
        #expect(AssetGridMetrics.cardHeight(gridWidth: 0) > AssetGridMetrics.captionHeight)
    }
}
