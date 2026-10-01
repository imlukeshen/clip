import Testing

@testable import Reel

@MainActor
@Suite("Mermaid error messages")
struct MermaidRendererTests {
    @Test("A parse error keeps where it is and what was found, not the token list")
    func parseErrorIsReadable() {
        let message = """
            Error: Parse error on line 3:
            ...flowchart TD    A -->
            ---------------------^
            Expecting 'AMP', 'COLON', 'PIPE', 'TESTSTR', 'DOWN', got 'EOF'
            """
        #expect(
            MermaidRenderer.readable(message)
                == "Parse error on line 3: the diagram ends too early"
        )
    }

    @Test("An unexpected token is named")
    func unexpectedToken() {
        let message = "Parse error on line 2:\n...\nExpecting 'SEMI', got 'NODE_STRING'"
        #expect(
            MermaidRenderer.readable(message) == "Parse error on line 2: unexpected NODE_STRING"
        )
    }

    @Test("Any other message passes through")
    func otherMessages() {
        #expect(MermaidRenderer.readable("No diagram type detected") == "No diagram type detected")
    }
}
