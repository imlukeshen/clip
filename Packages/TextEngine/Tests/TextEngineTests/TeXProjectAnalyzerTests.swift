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

@Test func texProjectExplicitMainSelectionWinsOverRootDirective() {
    let sources = [
        "chosen.tex": "Chosen without a document class",
        "main.tex": "\\documentclass{article}",
        "chapters/intro.tex": "% !TeX root = ../main.tex\nIntro",
    ]

    let mainFile = TeXProjectAnalyzer.inferMainFile(
        sources: sources,
        selectedMainFile: "chosen.tex"
    )

    #expect(mainFile == "chosen.tex")
}

@Test func texProjectUsesSafeRootMagicCommentBeforeDocumentClassInference() {
    let sources = [
        "paper.tex": "\\begin{document}Paper\\end{document}",
        "other.tex": "\\documentclass{article}",
        "chapters/intro.tex": "% !TEX root = ../paper\nIntro",
    ]

    let analysis = TeXProjectAnalyzer.analyze(
        sources: sources,
        availableFiles: Set(sources.keys)
    )

    #expect(analysis.mainFile == "paper.tex")
}

@Test func texProjectAcceptsQuotedRootMagicCommentPath() {
    let sources = [
        "My Paper.tex": "\\begin{document}Paper\\end{document}",
        "chapters/intro.tex": #"% !TeX root = "../My Paper.tex""#,
    ]

    #expect(TeXProjectAnalyzer.inferMainFile(sources: sources) == "My Paper.tex")
}

@Test func texProjectIgnoresUnsafeOrMissingRootMagicComments() {
    let sources = [
        "main.tex": "\\documentclass{article}",
        "chapters/escape.tex": "% !TeX root = ../../outside.tex",
        "chapters/absolute.tex": "% !TeX root = /tmp/outside.tex",
        "chapters/tmp/outside.tex": "Would be selected if the absolute path were rebased",
        "chapters/missing.tex": "% !TeX root = ../not-in-project.tex",
    ]

    #expect(TeXProjectAnalyzer.inferMainFile(sources: sources) == "main.tex")
}

@Test func texProjectRootInferenceUsesStableCandidateRanking() {
    let sources = [
        // Shallower candidates win before conventional naming.
        "paper.tex": "\\documentclass{article}\nA",
        "nested/main.tex": "\\documentclass{article}\nA much larger nested source",
    ]
    #expect(TeXProjectAnalyzer.inferMainFile(sources: sources) == "paper.tex")

    let conventionalSources = [
        "article.tex": "\\documentclass{article}\nA much larger root source",
        "main.tex": "\\documentclass{article}",
    ]
    #expect(TeXProjectAnalyzer.inferMainFile(sources: conventionalSources) == "main.tex")

    let sizedSources = [
        "alpha.tex": "\\documentclass{article}",
        "paper.tex": "\\documentclass{article}\nSubstantial project content",
    ]
    #expect(TeXProjectAnalyzer.inferMainFile(sources: sizedSources) == "alpha.tex")

    let lexicalSources = [
        "zeta.tex": "\\documentclass{book}",
        "Alpha.tex": "\\documentclass{book}",
    ]
    #expect(TeXProjectAnalyzer.inferMainFile(sources: lexicalSources) == "Alpha.tex")
}

@Test func texProjectRootInferenceIsIndependentOfDictionaryInsertionOrder() {
    let entries = [
        ("zeta.tex", "\\documentclass{book}"),
        ("alpha.tex", "\\documentclass{book}"),
        ("beta.tex", "\\documentclass{book}"),
    ]
    let forward = Dictionary(uniqueKeysWithValues: entries)
    let reverse = Dictionary(uniqueKeysWithValues: entries.reversed())

    #expect(TeXProjectAnalyzer.inferMainFile(sources: forward) == "alpha.tex")
    #expect(TeXProjectAnalyzer.inferMainFile(sources: reverse) == "alpha.tex")
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
