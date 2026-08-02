import AIKit
import AppKit
import CoreModel
import Foundation
import ReelAppCore
import Testing

@MainActor
@Test func suggestRedactionsFindsEmailOnDeviceWithoutEgress() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-ocr-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let imageURL = directory.appendingPathComponent("email.png")
    try emailScreenshot().writePNG(to: imageURL)
    let ledger = EgressLedger(storageURL: directory.appendingPathComponent("egress.json"))
    let document = try ImageDocument(
        sourceAssetID: AssetID(rawValue: "email-screenshot"),
        canvas: ImageCanvas(width: 1_200, height: 260)
    )

    let result = try await ImageToolExecutor().execute(
        ToolInvocation(
            callID: "redaction-test",
            name: "suggestRedactions",
            arguments: .object([:])
        ),
        context: ImageToolExecutionContext(document: document, sourceURL: imageURL)
    )

    #expect(result.patches.isEmpty, "Suggestions must never auto-apply")
    #expect(result.suggestions.contains(where: { $0.kind == .email }))
    #expect(await ledger.entries().isEmpty)
}

@Test func everyImageAIActionHasAValidCommandSchema() {
    let expected = Set([
        "cropTo", "addAnnotation", "suggestRedactions", "applyRedactions",
        "addPadding", "generateAltText", "numberSteps",
    ])
    let imageCommands = CommandRegistry.all.filter { $0.category == .image }
    #expect(Set(imageCommands.map(\.id.rawValue)) == expected)
    #expect(imageCommands.allSatisfy { $0.schema.hasValidObjectSchema })
    #expect(imageCommands.allSatisfy { $0.agentExposure != .never })
}

@MainActor
private func emailScreenshot() -> NSImage {
    let image = NSImage(size: NSSize(width: 1_200, height: 260))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    NSString(string: "Account email: person@example.com").draw(
        at: NSPoint(x: 42, y: 92),
        withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 52, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
    )
    image.unlockFocus()
    return image
}

extension NSImage {
    fileprivate func writePNG(to url: URL) throws {
        guard let tiff = tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
}
