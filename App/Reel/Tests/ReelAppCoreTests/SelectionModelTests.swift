import CoreGraphics
import CoreModel
import ReelAppCore
import Testing

@MainActor
@Test func selectionSupportsFinderStyleClicksAndRanges() {
    let ids = (0..<6).map { AssetID(rawValue: "asset-\($0)") }
    let selection = SelectionModel()
    selection.setItems(ids)

    selection.click(ids[1])
    selection.click(ids[3], modifiers: [.command])
    #expect(selection.selected == [ids[1], ids[3]])

    selection.click(ids[5], modifiers: [.shift])
    #expect(selection.selected == Set(ids[3...5]))

    selection.selectAll()
    #expect(selection.selected == Set(ids))
    selection.deselectAll()
    #expect(selection.selected.isEmpty)
}

@MainActor
@Test func marqueeUsesCentralLayoutFramesAndCanBeAdditive() {
    let first = AssetID(rawValue: "first")
    let second = AssetID(rawValue: "second")
    let third = AssetID(rawValue: "third")
    let selection = SelectionModel()
    selection.setItems([first, second, third])
    let layout = GridLayout(frames: [
        first: CGRect(x: 0, y: 0, width: 100, height: 100),
        second: CGRect(x: 110, y: 0, width: 100, height: 100),
        third: CGRect(x: 220, y: 0, width: 100, height: 100),
    ])

    selection.marquee(CGRect(x: 5, y: 5, width: 190, height: 50), in: layout, additive: false)
    #expect(selection.selected == [first, second])
    selection.marquee(CGRect(x: 225, y: 5, width: 20, height: 20), in: layout, additive: true)
    #expect(selection.selected == [first, second, third])
}
