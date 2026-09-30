import CoreModel
import Foundation
import Testing

@testable import AIKit

@Suite("Workspace tool exposure")
struct WorkspaceToolExposureTests {
    @Test("Redaction is offered directly while a PDF is open")
    func pdfToolsExpandForPDFWorkspace() {
        let always = ToolCatalog.all.map(\.name)
        // On-demand, so the model was never shown it and had to find the name
        // through meta-tool discovery. A small local model does not, which made
        // "redact this word" a long wait that changed nothing.
        #expect(!always.contains("pdf.redact"))

        let expanded = ToolCatalog.all(expanding: [.pdf]).map(\.name)
        #expect(expanded.contains("pdf.redact"))
    }

    @Test("Only the open workspace's tools are expanded")
    func otherWorkspacesStayCollapsed() {
        let expanded = ToolCatalog.all(expanding: [.pdf])
        let everything = ToolCatalog.all(expanding: Set(CommandCategory.allCases))
        // Every schema costs context the model reads before answering, so the
        // timeline's tools have no business being expanded under a PDF.
        #expect(expanded.count < everything.count)
        #expect(ToolCatalog.all.count < expanded.count)
    }

    @Test("Expanding nothing matches the plain catalog")
    func emptyExpansionIsTheDefault() {
        #expect(ToolCatalog.all(expanding: []).map(\.name) == ToolCatalog.all.map(\.name))
    }

    @Test("Never-exposed commands stay hidden however much is expanded")
    func neverStaysNever() {
        let everything = ToolCatalog.all(expanding: Set(CommandCategory.allCases)).map(\.name)
        let hidden = CommandRegistry.all.filter { $0.agentExposure == .never }.map(\.id.rawValue)
        #expect(!hidden.isEmpty)
        for name in hidden { #expect(!everything.contains(name)) }
    }
}
