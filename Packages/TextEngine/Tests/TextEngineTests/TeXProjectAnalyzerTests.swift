import Testing

@testable import TextEngine

@Test func texProjectInfersMainAndTraversesThreeFilesWithBibTeX() throws {
    let sources = [
        "main.tex": """
        \\documentclass{article}
        \\begin{document}
        \\input{chapters/intro}
        \\bibliography{refs}
        \\end{document}
        """,
        "chapters/intro.tex": "Intro \\input{details}",
        "chapters/details.tex": "Details",
        "unused.tex": "Not included",
        "refs.bib": "@book{clip, title={Clip}}",
    ]
    let analysis = TeXProjectAnalyzer.analyze(
        sources: sources,
        availableFiles: Set(sources.keys)
    )

    #expect(analysis.mainFile == "main.tex")
    #expect(
        analysis.reachableFiles
            == ["main.tex", "chapters/intro.tex", "chapters/details.tex", "refs.bib"]
    )
    #expect(analysis.unreachableTeXFiles == ["unused.tex"])
    #expect(analysis.missingDependencies.isEmpty)
    #expect(analysis.bibliography == .bibtex)
}

@Test func texProjectHonorsMainOverrideAndDetectsBiberAndMissingFiles() {
    let sources = [
        "a.tex": "\\documentclass{article}",
        "book.tex": "\\documentclass{book}\\addbibresource{library.bib}\\input{missing}",
        "library.bib": "@article{one}",
    ]
    let analysis = TeXProjectAnalyzer.analyze(
        sources: sources,
        availableFiles: Set(sources.keys),
        selectedMainFile: "book.tex"
    )

    #expect(analysis.mainFile == "book.tex")
    #expect(analysis.bibliography == .biber)
    #expect(analysis.missingDependencies == ["missing.tex"])
    #expect(analysis.unreachableTeXFiles == ["a.tex"])
}

@Test func texProjectAcceptsTheLatexExtensionAsAMainSource() {
    let analysis = TeXProjectAnalyzer.analyze(
        sources: ["paper.latex": "\\documentclass{article}"],
        availableFiles: ["paper.latex"]
    )

    #expect(analysis.mainFile == "paper.latex")
    #expect(analysis.reachableFiles == ["paper.latex"])
}

@Test func texProjectAcceptsAColonInAFilename() {
    let path = "chapters/launch:final.tex"
    let analysis = TeXProjectAnalyzer.analyze(
        sources: [path: "\\documentclass{article}"],
        availableFiles: [path],
        selectedMainFile: path
    )

    #expect(analysis.mainFile == path)
    #expect(analysis.reachableFiles == [path])
}

@Test func texProjectRejectsTraversalAndCopiesReferencedLocalResourcesOnly() {
    let sources = [
        "main.tex": """
        \\documentclass{local}
        \\usepackage{theme}
        \\includegraphics{art/figure}
        \\input{../../secret}
        """,
        "local.cls": "",
        "theme.sty": "",
    ]
    let available = Set(sources.keys).union(["art/figure.png", "unrelated.png"])
    let analysis = TeXProjectAnalyzer.analyze(
        sources: sources,
        availableFiles: available
    )

    #expect(analysis.reachableFiles.contains("local.cls"))
    #expect(analysis.reachableFiles.contains("theme.sty"))
    #expect(analysis.reachableFiles.contains("art/figure.png"))
    #expect(!analysis.reachableFiles.contains("unrelated.png"))
    #expect(!analysis.reachableFiles.contains("../../secret.tex"))
}
