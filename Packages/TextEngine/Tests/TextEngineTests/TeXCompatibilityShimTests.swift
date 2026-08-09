import Foundation
import Testing

@testable import TextEngine

@Suite("TeX XeTeX compatibility shim")
struct TeXCompatibilityShimTests {
    /// The pdfLaTeX CV templates in wide circulation input `glyphtounicode`
    /// unconditionally, and every mapping line inside it is an undefined
    /// control sequence under the XeTeX engine Clip compiles with.
    @Test("A document reaching for the pdfTeX glyph table gets XeTeX definitions")
    func documentInputtingGlyphTableGetsShim() throws {
        let fixture = try ShimFixture(
            main: """
                \\documentclass{article}
                \\input{glyphtounicode}
                \\pdfgentounicode=1
                \\begin{document}Clip\\end{document}
                """
        )
        defer { fixture.remove() }

        let workspace = try TeXWorkspaceSandbox.prepare(fixture.job)
        defer { workspace.remove() }

        #expect(try workspace.installXeTeXCompatibilityShim())
        let installed = try String(
            contentsOf: workspace.source.appendingPathComponent(
                TeXWorkspaceSandbox.xeTeXCompatibilityShimName
            ),
            encoding: .utf8
        )
        #expect(installed.contains("\\providecommand\\pdfglyphtounicode"))
        // The document assigns to \pdfgentounicode straight after the input,
        // so the substitution has to leave an assignable register behind.
        #expect(installed.contains("\\newcount\\pdfgentounicode"))
    }

    @Test("A document that never reaches for the glyph table is left alone")
    func ordinaryDocumentIsUntouched() throws {
        let fixture = try ShimFixture(
            main: "\\documentclass{article}\n\\begin{document}Clip\\end{document}"
        )
        defer { fixture.remove() }

        let workspace = try TeXWorkspaceSandbox.prepare(fixture.job)
        defer { workspace.remove() }

        #expect(try workspace.installXeTeXCompatibilityShim() == false)
        #expect(
            !FileManager.default.fileExists(
                atPath: workspace.source.appendingPathComponent(
                    TeXWorkspaceSandbox.xeTeXCompatibilityShimName
                ).path
            )
        )
    }

    @Test("A project shipping its own glyph table keeps it")
    func authoredGlyphTableSurvives() throws {
        let authored = "% mine\n\\providecommand\\pdfglyphtounicode[2]{}\n"
        let fixture = try ShimFixture(
            main: "\\documentclass{article}\n\\input{glyphtounicode}\n",
            extraFiles: [TeXWorkspaceSandbox.xeTeXCompatibilityShimName: authored]
        )
        defer { fixture.remove() }

        let workspace = try TeXWorkspaceSandbox.prepare(fixture.job)
        defer { workspace.remove() }

        #expect(try workspace.installXeTeXCompatibilityShim() == false)
        let contents = try String(
            contentsOf: workspace.source.appendingPathComponent(
                TeXWorkspaceSandbox.xeTeXCompatibilityShimName
            ),
            encoding: .utf8
        )
        #expect(contents == authored)
    }

    @Test("An input from a secondary file is found too")
    func inputFromIncludedFileIsFound() throws {
        let fixture = try ShimFixture(
            main: "\\documentclass{article}\n\\input{preamble}\n",
            extraFiles: ["preamble.tex": "\\input{glyphtounicode}\n"]
        )
        defer { fixture.remove() }

        let workspace = try TeXWorkspaceSandbox.prepare(fixture.job)
        defer { workspace.remove() }

        #expect(try workspace.installXeTeXCompatibilityShim())
    }
}

private struct ShimFixture {
    let root: URL
    let job: TeXJob

    init(main: String, extraFiles: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-shim-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mainFile = root.appendingPathComponent("main.tex")
        try Data(main.utf8).write(to: mainFile)
        var files = [mainFile]
        for (name, contents) in extraFiles {
            let url = root.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            files.append(url)
        }
        job = TeXJob(
            mainFile: mainFile,
            workingDirectory: root,
            projectFiles: files,
            timeout: .seconds(2),
            packageAccess: .cachedOnly
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
