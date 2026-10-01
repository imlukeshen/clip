import AIKit
import CoreModel
import Testing

@Suite("Tool parameter descriptions")
struct ToolParameterDescriptionTests {
    private func description(_ tool: String, _ parameter: String) -> String? {
        guard
            case .string(let text)? = ToolCatalog.schema(named: tool)?
                .parameters["properties"]?[parameter]?["description"]
        else { return nil }
        return text
    }

    @Test("Times say what they are measured from")
    func timesNameTheirReference() {
        // The two clip tools a person reaches for first measure time
        // differently, and a bare `number` gave a model no way to know.
        #expect(description("trimClip", "start")?.contains("source") == true)
        #expect(description("trimClip", "end")?.contains("source") == true)
        #expect(description("splitClip", "at")?.contains("project") == true)
        #expect(description("addZoom", "range")?.contains("clip") == true)
        #expect(description("setKeyframe", "time")?.contains("Seconds") == true)
    }

    @Test("Parameters with a fixed set of values list them")
    func enumeratedValuesAreListed() {
        #expect(description("setKeyframe", "property")?.contains("opacity") == true)
        #expect(description("generateCaptions", "engine")?.contains("onDevice") == true)
        #expect(description("search.library", "mode")?.contains("semantic") == true)
        #expect(description("timeline.setTrackState", "property")?.contains("muted") == true)
        #expect(description("addAnnotation", "type")?.contains("arrow") == true)
    }

    @Test("Rectangles say they are fractions, not pixels")
    func rectanglesNameTheirUnits() {
        #expect(description("pdf.redact", "rect")?.contains("0 to 1") == true)
        #expect(description("cropTo", "rect")?.contains("0 to 1") == true)
    }

    @Test("Describing a parameter leaves every schema valid")
    func schemasStayValid() {
        #expect(CommandRegistry.all.allSatisfy { $0.schema.hasValidObjectSchema })
        // A described nested object still declares its own shape.
        let range = ToolCatalog.schema(named: "addZoom")?.parameters["properties"]?["range"]
        #expect(range?["type"] == .string("object"))
        #expect(range?["properties"]?["start"] != nil)
    }
}
