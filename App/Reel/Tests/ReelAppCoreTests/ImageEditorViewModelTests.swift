import CoreGraphics
import CoreModel
import Foundation
import ReelAppCore
import Testing

@MainActor
@Test func cropAnnotationAndPaddingEachUndoExactly() throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-image-editor-\(UUID().uuidString).png"
    )
    defer { try? FileManager.default.removeItem(at: source) }
    let tinyPNG = try #require(
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )
    )
    try tinyPNG.write(to: source)
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
