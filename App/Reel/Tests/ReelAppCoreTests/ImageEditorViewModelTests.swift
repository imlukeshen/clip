import CoreGraphics
import CoreModel
import Foundation
import ReelAppCore
import Testing

@MainActor
@Test func liveTextRegionsBecomeOneUndoableRedactionLayer() throws {
    let source = try temporaryImageSource()
    defer { try? FileManager.default.removeItem(at: source) }
    let original = try ImageDocument(
        id: DocumentID(rawValue: "live-text-redaction-test"),
        sourceAssetID: AssetID(rawValue: "image-source"),
        canvas: ImageCanvas(width: 1_200, height: 800)
    )
    let editor = ImageEditorViewModel(
        document: original,
        sourceURL: source,
        persisting: { _ in }
    )

    editor.addRedaction(regions: [
        NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
        NormalizedRect(x: 0.55, y: 0.6, width: 0.2, height: 0.1),
    ])

    guard case .redaction(let redaction) = editor.document.layers.first else {
        Issue.record("Expected one redaction layer")
        return
    }
    #expect(redaction.regions.count == 2)
    editor.undo()
    #expect(editor.document == original)
    editor.stop()
}

@MainActor
@Test func cropAnnotationAndPaddingEachUndoExactly() throws {
    let source = try temporaryImageSource()
    defer { try? FileManager.default.removeItem(at: source) }
    let original = try ImageDocument(
        id: DocumentID(rawValue: "editor-test"),
        sourceAssetID: AssetID(rawValue: "image-source"),
        canvas: ImageCanvas(width: 100, height: 100)
    )
    let editor = ImageEditorViewModel(
        document: original,
        sourceURL: source,
        persisting: { _ in }
    )

    editor.cropToInset()
    editor.activate(.arrow)
    editor.commitGesture(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.7, y: 0.7))
    editor.addPadding()
    #expect(editor.document.layers.count == 2)
    #expect(editor.document.geometry.crop != original.geometry.crop)

    editor.undo()
    editor.undo()
    editor.undo()
    #expect(editor.document == original)

    editor.redo()
    editor.redo()
    editor.redo()
    #expect(editor.document.layers.count == 2)
    #expect(editor.document.geometry.crop != original.geometry.crop)
    editor.stop()
}

@MainActor
@Test func cropToolStagesAnAspectCropAndCommitsOneUndoableEdit() throws {
    let source = try temporaryImageSource()
    defer { try? FileManager.default.removeItem(at: source) }
    let sourceCanvas = ImageCanvas(width: 1_200, height: 800)
    let original = try ImageDocument(
        id: DocumentID(rawValue: "crop-workflow-test"),
        sourceAssetID: AssetID(rawValue: "crop-source"),
        canvas: sourceCanvas
    )
    let editor = ImageEditorViewModel(
        document: original,
        sourceURL: source,
        sourceCanvas: sourceCanvas,
        persisting: { _ in }
    )

    editor.activate(.crop)
    #expect(editor.document == original)
    editor.stageCrop(aspectRatio: 1)
    #expect(editor.pendingCrop != nil)
    editor.applyPendingCrop()
    #expect(editor.pendingCrop == nil)
    #expect(editor.document.canvas.width == 800)
    #expect(editor.document.canvas.height == 800)
    #expect(editor.document.geometry.crop.width > 0.66)
    #expect(editor.document.geometry.crop.width < 0.67)

    editor.undo()
    #expect(editor.document == original)
    editor.stop()
}

@MainActor
@Test func drawingToolsAcceptStraightLinesAndKeepTheFullFreehandPath() throws {
    let source = try temporaryImageSource()
    defer { try? FileManager.default.removeItem(at: source) }
    let document = try ImageDocument(
        id: DocumentID(rawValue: "drawing-gesture-test"),
        sourceAssetID: AssetID(rawValue: "drawing-source"),
        canvas: ImageCanvas(width: 800, height: 600)
    )
    let editor = ImageEditorViewModel(
        document: document,
        sourceURL: source,
        persisting: { _ in }
    )

    editor.activate(.arrow)
    editor.commitGesture(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.8, y: 0.5))
    #expect(editor.document.layers.count == 1)

    let path = [
        CGPoint(x: 0.2, y: 0.2),
        CGPoint(x: 0.3, y: 0.4),
        CGPoint(x: 0.45, y: 0.25),
        CGPoint(x: 0.6, y: 0.45),
    ]
    editor.activate(.freehand)
    editor.commitGesture(points: path)
    #expect(editor.document.layers.count == 2)
    guard case .annotation(let freehand) = editor.document.layers.last else {
        Issue.record("Expected a freehand annotation")
        editor.stop()
        return
    }
    #expect(freehand.kind == .freehand)
    #expect(freehand.points == path)
    editor.stop()
}

@MainActor
@Test func selectedLayersCanMoveAndChangePropertiesThroughTheInspectorPath() throws {
    let source = try temporaryImageSource()
    defer { try? FileManager.default.removeItem(at: source) }
    let layer = Layer.annotation(
        AnnotationLayer(
            kind: .box,
            bounds: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        )
    )
    let document = try ImageDocument(
        id: DocumentID(rawValue: "layer-properties-test"),
        sourceAssetID: AssetID(rawValue: "layer-source"),
        canvas: ImageCanvas(width: 800, height: 600),
        layers: [layer]
    )
    let editor = ImageEditorViewModel(
        document: document,
        sourceURL: source,
        persisting: { _ in }
    )

    editor.selectLayer(at: CGPoint(x: 0.15, y: 0.15))
    #expect(editor.selectedLayerID == layer.id)
    editor.moveSelectedLayer(by: CGPoint(x: 0.2, y: 0.1))
    editor.updateSelectedStrokeWidth(9)

    guard case .annotation(let updated) = editor.selectedLayer else {
        Issue.record("Expected the selected annotation")
        editor.stop()
        return
    }
    #expect(abs(updated.bounds.origin.x - 0.3) < 0.000_001)
    #expect(abs(updated.bounds.origin.y - 0.2) < 0.000_001)
    #expect(updated.strokeWidth == 9)

    editor.undo()
    editor.undo()
    #expect(editor.document == document)
    editor.stop()
}

private func temporaryImageSource() throws -> URL {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-image-editor-\(UUID().uuidString).png"
    )
    let tinyPNG = try #require(
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )
    )
    try tinyPNG.write(to: source)
    return source
}
