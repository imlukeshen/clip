import CoreGraphics
import CoreModel
import Foundation
import Observation

public struct EventModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = EventModifiers(rawValue: 1 << 0)
    public static let shift = EventModifiers(rawValue: 1 << 1)
}

public struct GridLayout: Sendable {
    public var frames: [AssetID: CGRect]

    public init(frames: [AssetID: CGRect]) {
        self.frames = frames
    }

    public func assets(intersecting rect: CGRect) -> Set<AssetID> {
        Set(frames.compactMap { id, frame in frame.intersects(rect) ? id : nil })
    }
}

@MainActor
@Observable
public final class SelectionModel {
    public private(set) var selected: Set<AssetID> = []
    public private(set) var anchor: AssetID?
    private var orderedIDs: [AssetID] = []

    public init() {}

    public func setItems(_ ids: [AssetID]) {
        orderedIDs = ids
        let available = Set(ids)
        selected.formIntersection(available)
        if let anchor, !available.contains(anchor) {
            self.anchor = nil
        }
    }

    public func click(_ id: AssetID, modifiers: EventModifiers = []) {
        if modifiers.contains(.shift), let anchor,
            let anchorIndex = orderedIDs.firstIndex(of: anchor),
            let clickedIndex = orderedIDs.firstIndex(of: id)
        {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let ranged = Set(range.map { orderedIDs[$0] })
            if modifiers.contains(.command) {
                selected.formUnion(ranged)
            } else {
                selected = ranged
            }
            return
        }

        if modifiers.contains(.command) {
            if selected.contains(id) {
                selected.remove(id)
            } else {
                selected.insert(id)
            }
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
    }

    public func selectAll() {
        selected = Set(orderedIDs)
        anchor = orderedIDs.first
    }

    public func deselectAll() {
        selected.removeAll()
        anchor = nil
    }

    public func marquee(_ rect: CGRect, in layout: GridLayout, additive: Bool) {
        let hit = layout.assets(intersecting: rect.standardized)
        if additive {
            selected.formUnion(hit)
        } else {
            selected = hit
        }
        anchor = orderedIDs.first(where: selected.contains)
    }

    public func move(by offset: Int, extending: Bool) {
        guard !orderedIDs.isEmpty else { return }
        let current = anchor.flatMap { orderedIDs.firstIndex(of: $0) }
            ?? (offset >= 0 ? -1 : orderedIDs.count)
        let next = min(max(current + offset, 0), orderedIDs.count - 1)
        click(orderedIDs[next], modifiers: extending ? [.shift] : [])
    }
}
