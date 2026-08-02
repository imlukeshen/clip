import AIKit
import Testing

@Test func toolCatalogHasTheSpecifiedSurface() {
    #expect(
        ToolCatalog.all.map(\.name) == [
            "describeTimeline", "describeClip", "trimClip", "splitClip", "reorderClips",
            "setSpeed", "addZoom", "autoZoomFromClicks", "removeEffect", "setBackground",
            "detectSilence", "trimSilence", "generateCaptions", "exportProject", "setPreference",
        ])
    #expect(ToolCatalog.all.filter { $0.kind == .write }.count == 10)
    #expect(ToolCatalog.all.filter { $0.kind == .confirm }.count == 2)
}

@Test func contextDigestCapsItemsAndRetainsCapabilityFacts() throws {
    let items = (0..<45).map {
        ContextItem(
            id: "item-\($0)", name: "Clip \($0)", duration: 2,
            hasAudio: $0 == 0, clicks: $0, effects: [], alignment: "exact")
    }
    let digest = ContextDigest(
        projectName: "Demo", duration: 90, canvas: "1920x1080@60",
        selectedItemID: "item-0", items: items)
    #expect(digest.items.count == 40)
    #expect(digest.omittedItemCount == 5)
    let json = try digest.encodedString()
    #expect(json.contains("hasAudio"))
    #expect(json.contains("alignment"))
}

@Test(arguments: ConfirmationPolicy.allCases)
func externalEffectsAlwaysConfirm(_ policy: ConfirmationPolicy) {
    #expect(policy.requiresConfirmation(for: .confirm))
}
