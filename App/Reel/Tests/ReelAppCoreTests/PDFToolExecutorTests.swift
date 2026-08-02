import AIKit
import CoreModel
import Testing

@testable import ReelAppCore

@Suite("PDF command parity")
struct PDFToolExecutorTests {
    @Test("Every PDF action has a valid assistant schema")
    func commandSchemas() {
        let expected = Set([
            "pdf.describe", "pdf.addText", "pdf.highlight", "pdf.redact",
            "pdf.rotatePage", "pdf.reorderPage", "pdf.ocrPage", "pdf.toMarkdown",
        ])
        let commands = CommandRegistry.all.filter { $0.category == .pdf }
        #expect(Set(commands.map(\.id.rawValue)) == expected)
        #expect(commands.allSatisfy { $0.schema.hasValidObjectSchema })
        #expect(commands.allSatisfy { $0.agentExposure != .never })
    }

    @Test("All PDF commands execute through the shared patch path")
    func commandExecution() async throws {
        let document = try fixtureDocument()
        let context = PDFToolExecutionContext(
            document: document,
            selectedPageID: document.pages[0].id
        )
        let executor = PDFToolExecutor(
            recognizer: { _, _ in "LOCAL OCR" },
            markdownConverter: { _ in "# Converted\n" }
        )
        let invocations: [(String, JSONValue)] = [
            ("pdf.describe", .object([:])),
            (
                "pdf.addText",
                .object([
                    "text": .string("Reviewed"), "rect": rect,
                    "fontSize": .number(16),
                ])
            ),
            ("pdf.highlight", .object(["rect": rect])),
            ("pdf.redact", .object(["rect": rect])),
            ("pdf.rotatePage", .object([:])),
            ("pdf.reorderPage", .object(["destination": .number(1)])),
            ("pdf.ocrPage", .object([:])),
            ("pdf.toMarkdown", .object([:])),
        ]

        var results: [String: PDFToolResult] = [:]
        for (name, arguments) in invocations {
            let result = try await executor.execute(
                ToolInvocation(callID: name, name: name, arguments: arguments),
                context: context
            )
            results[name] = result
            var candidate = document
            for patch in result.patches { _ = try candidate.apply(patch) }
        }

        #expect(results["pdf.describe"]?.patches.isEmpty == true)
        #expect(results["pdf.addText"]?.patches.count == 1)
        #expect(results["pdf.highlight"]?.patches.count == 1)
        #expect(results["pdf.redact"]?.patches.count == 1)
        #expect(results["pdf.rotatePage"]?.patches.count == 1)
        #expect(results["pdf.reorderPage"]?.patches.count == 1)
        #expect(results["pdf.ocrPage"]?.value == "LOCAL OCR")
        #expect(results["pdf.toMarkdown"]?.value == "# Converted\n")
    }

    private var rect: JSONValue {
        .object([
            "x": .number(0.1), "y": .number(0.2),
            "width": .number(0.3), "height": .number(0.1),
        ])
    }

    private func fixtureDocument() throws -> PDFEditDocument {
        try PDFEditDocument(
            sourceAssetID: AssetID(rawValue: "pdf-command-fixture"),
            title: "Fixture",
            pages: [
                PDFPage(sourcePageIndex: 0, size: PDFPageSize(width: 612, height: 792)),
                PDFPage(sourcePageIndex: 1, size: PDFPageSize(width: 612, height: 792)),
            ]
        )
    }
}
