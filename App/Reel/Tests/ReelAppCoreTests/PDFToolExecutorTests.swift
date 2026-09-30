import AIKit
import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("PDF command parity")
struct PDFToolExecutorTests {
    @Test("Every PDF action has a valid assistant schema")
    func commandSchemas() {
        let expected = Set([
            "pdf.describe", "pdf.addText", "pdf.highlight", "pdf.redact",
            "pdf.rotatePage", "pdf.reorderPage", "pdf.ocrPage", "pdf.toMarkdown",
            // Redaction takes a rectangle, and nothing told the assistant where
            // a word was, so "redact this name" had no path to an argument.
            "pdf.findText", "pdf.redactText",
        ])
        let commands = CommandRegistry.all.filter { $0.category == .pdf }
        #expect(Set(commands.map(\.id.rawValue)) == expected)
        #expect(commands.allSatisfy { $0.schema.hasValidObjectSchema })
        #expect(commands.allSatisfy { $0.agentExposure != .never })
    }

    @Test("A page id the model invented searches the whole document, not none")
    func unknownPageIdDoesNotNarrowToNothing() async throws {
        let document = try fixtureDocument()
        let requested = PageRecorder()
        var context = PDFToolExecutionContext(
            document: document,
            selectedPageID: document.pages[0].id
        )
        context.locatingText = { _, _, page in
            await requested.record(page)
            return []
        }
        let executor = PDFToolExecutor(
            recognizer: { _, _ in "" },
            markdownConverter: { _ in "" }
        )

        // Page ids are opaque UUIDs. A model told to redact a word cannot know
        // one, so it fills the optional with something plausible — and passing
        // that through searched no pages and reported the word absent.
        _ = try await executor.execute(
            ToolInvocation(
                callID: "call",
                name: "pdf.findText",
                arguments: .object(["text": .string("jiawei"), "pageID": .string("1")])
            ),
            context: context
        )
        #expect(await requested.value == .some(nil))

        // A real page id still narrows the search.
        _ = try await executor.execute(
            ToolInvocation(
                callID: "call",
                name: "pdf.findText",
                arguments: .object([
                    "text": .string("jiawei"),
                    "pageID": .string(document.pages[0].id.rawValue),
                ])
            ),
            context: context
        )
        #expect(await requested.value == .some(document.pages[0].id))
    }

    @Test("Redacting several occurrences leaves each one separately removable")
    func redactTextMakesOneLayerPerMatch() async throws {
        let document = try fixtureDocument()
        let page = document.pages[0]
        var context = PDFToolExecutionContext(document: document, selectedPageID: page.id)
        context.locatingText = { _, _, _ in
            [0.2, 0.4, 0.6].map {
                PDFTextMatch(
                    pageID: page.id,
                    rect: CGRect(x: $0, y: 0.5, width: 0.05, height: 0.01),
                    snippet: "jiawei"
                )
            }
        }
        let result = try await PDFToolExecutor(
            recognizer: { _, _ in "" },
            markdownConverter: { _ in "" }
        ).execute(
            ToolInvocation(
                callID: "call",
                name: "pdf.redactText",
                arguments: .object(["text": .string("jiawei")])
            ),
            context: context
        )

        // One patch, so the run is a single undo.
        #expect(result.patches.count == 1)
        guard case .updatePage(let updated)? = result.patches.first else {
            Issue.record("expected a page update")
            return
        }
        let added = updated.layers.compactMap { layer -> PDFRedactionLayer? in
            guard case .redaction(let redaction) = layer else { return nil }
            return redaction
        }
        // Three layers, not one holding three regions: a layer is the unit of
        // selection, so batching them would make an unwanted occurrence
        // removable only by taking back the others.
        #expect(added.count == 3)
        #expect(added.allSatisfy { $0.regions.count == 1 })
        #expect(Set(added.map(\.id)).count == 3)
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

private actor PageRecorder {
    private(set) var value: PDFPageID??
    func record(_ page: PDFPageID?) { value = .some(page) }
}
