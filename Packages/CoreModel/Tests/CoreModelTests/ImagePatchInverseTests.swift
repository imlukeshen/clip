import CoreGraphics
import CoreModel
import Testing

@Test func imagePatchAndInverseRestoreIdentityAcrossOneThousandRandomSequences() throws {
    var random = ImageRandom(seed: 0x1A6E_CAFE)

    for sequence in 0..<1_000 {
        let original = try ImageDocument(
            id: DocumentID(rawValue: "image-\(sequence)"),
            sourceAssetID: AssetID(rawValue: "source-\(sequence)"),
            canvas: ImageCanvas(width: 1_280, height: 720)
        )
        var document = original
        var inverses: [ImagePatch] = []

        for step in 0..<random.int(in: 3...14) {
            let patch = randomPatch(
                sequence: sequence,
                step: step,
                document: document,
                random: &random
            )
            inverses.append(try document.apply(patch))
        }

        for inverse in inverses.reversed() {
            _ = try document.apply(inverse)
        }
        #expect(document == original, "Image sequence \(sequence) did not restore identity")
    }
}

@Test func imagePatchRejectsInvalidMutationTransactionally() throws {
    var document = try ImageDocument(
        sourceAssetID: AssetID(rawValue: "source"),
        canvas: ImageCanvas(width: 800, height: 600)
    )
    let original = document
    do {
        _ = try document.apply(.setGeometry(Geometry(scale: 0)))
        Issue.record("Expected invalid geometry")
    } catch {
        #expect(error as? ImageDocumentError == .invalidGeometry)
    }
    #expect(document == original)
}

private func randomPatch(
    sequence: Int,
    step: Int,
    document: ImageDocument,
    random: inout ImageRandom
) -> ImagePatch {
    switch random.int(in: 0...5) {
    case 0:
        return .addLayer(
            randomLayer(id: "layer-\(sequence)-\(step)", random: &random),
            atIndex: random.int(in: 0...document.layers.count)
        )
    case 1 where !document.layers.isEmpty:
        return .removeLayer(document.layers[random.int(in: 0...(document.layers.count - 1))].id)
    case 2 where !document.layers.isEmpty:
        let index = random.int(in: 0...(document.layers.count - 1))
        return .updateLayer(updated(document.layers[index]))
    case 3 where document.layers.count > 1:
        let index = random.int(in: 0...(document.layers.count - 1))
        return .reorderLayer(
            document.layers[index].id,
            to: random.int(in: 0...(document.layers.count - 1))
        )
    case 4:
        return .setGeometry(
            Geometry(
                crop: CGRect(x: 0, y: 0, width: random.bool() ? 1 : 0.8, height: 1),
                rotationDegrees: Double(random.int(in: -3...3)) * 90,
                isFlippedHorizontally: random.bool(),
                scale: random.bool() ? 1 : 1.25
            )
        )
    default:
        return .setCanvas(
            ImageCanvas(
                width: random.bool() ? 1_280 : 1_920,
                height: random.bool() ? 720 : 1_080,
                orientation: ImageOrientation.allCases[random.int(in: 0...3)]
            )
        )
    }
}

private func randomLayer(id: String, random: inout ImageRandom) -> Layer {
    let layerID = LayerID(rawValue: id)
    let rect = CGRect(x: 0.15, y: 0.2, width: 0.35, height: 0.25)
    switch random.int(in: 0...6) {
    case 0: return .annotation(AnnotationLayer(id: layerID, kind: .arrow, bounds: rect))
    case 1: return .text(TextLayer(id: layerID, text: "Note", frame: rect))
    case 2: return .highlight(HighlightLayer(id: layerID, regions: [rect]))
    case 3:
        return .redaction(RedactionLayer(id: layerID, regions: [rect], style: .pixelate(size: 12)))
    case 4: return .blur(BlurLayer(id: layerID, regions: [rect]))
    case 5: return .padding(PaddingLayer(id: layerID, amount: 0.1))
    default: return .step(StepLayer(id: layerID, number: 1, position: CGPoint(x: 0.3, y: 0.4)))
    }
}

private func updated(_ layer: Layer) -> Layer {
    switch layer {
    case .annotation(var value):
        value.strokeWidth += 1
        return .annotation(value)
    case .text(var value):
        value.text += "!"
        return .text(value)
    case .highlight(var value):
        value.color.a = value.color.a == 0.35 ? 0.5 : 0.35
        return .highlight(value)
    case .redaction(var value):
        value.style = .solid(.black)
        return .redaction(value)
    case .blur(var value):
        value.radius += 1
        return .blur(value)
    case .padding(var value):
        value.amount = value.amount == 0.1 ? 0.12 : 0.1
        return .padding(value)
    case .step(var value):
        value.number += 1
        return .step(value)
    }
}

private struct ImageRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func bool() -> Bool { next().isMultiple(of: 2) }
}
