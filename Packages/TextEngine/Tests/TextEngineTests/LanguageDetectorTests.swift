import CoreModel
import Testing

@testable import TextEngine

@Test func extensionDrivesDetectionForCommonLanguages() {
    #expect(LanguageDetector.detect(path: "main.swift") == .swift)
    #expect(LanguageDetector.detect(path: "README.md") == .markdown)
    #expect(LanguageDetector.detect(path: "paper.tex") == .latex)
    #expect(LanguageDetector.detect(path: "app.ts") == .typescript)
    #expect(LanguageDetector.detect(path: "component.tsx") == .typescript)
    #expect(LanguageDetector.detect(path: "styles.css") == .css)
    #expect(LanguageDetector.detect(path: "data.json") == .json)
}

@Test func collapsedExtensionsShareOneGrammar() {
    #expect(LanguageDetector.detect(path: "header.h") == .c)
    #expect(LanguageDetector.detect(path: "widget.hpp") == .cpp)
    #expect(LanguageDetector.detect(path: "module.mjs") == .javascript)
}

@Test func extensionlessFilesKeyOffTheirName() {
    #expect(LanguageDetector.detect(path: "Makefile") == .bash)
    #expect(LanguageDetector.detect(path: "Dockerfile") == .bash)
    #expect(LanguageDetector.detect(path: "/repo/.bashrc") == .bash)
}

@Test func shebangResolvesLanguageWhenExtensionIsAbsent() {
    #expect(LanguageDetector.detect(path: "run", contents: "#!/usr/bin/env python3\n") == .python)
    #expect(LanguageDetector.detect(path: "deploy", contents: "#!/bin/bash\n") == .bash)
    #expect(LanguageDetector.detect(path: "server", contents: "#!/usr/bin/node\n") == .javascript)
}

@Test func extensionWinsOverShebang() {
    // A `.swift` file starting with a shell-looking line is still Swift.
    #expect(
        LanguageDetector.detect(path: "tool.swift", contents: "#!/usr/bin/env swift\n") == .swift
    )
}

@Test func unknownFilesFallBackToPlainText() {
    #expect(LanguageDetector.detect(path: "mystery.qwerty") == .plainText)
    #expect(LanguageDetector.detect(path: "noextension", contents: "just words") == .plainText)
}

@Test func highConfidenceContentHeuristicsResolveExtensionlessFiles() {
    #expect(
        LanguageDetector.detect(
            path: "paper",
            contents: "\\documentclass{article}\n\\begin{document}\nHello"
        ) == .latex
    )
    #expect(
        LanguageDetector.detect(path: "feed", contents: "  <?xml version=\"1.0\"?><feed />")
            == .xml
    )
    #expect(LanguageDetector.detect(path: "payload", contents: " {\"clip\": true} ") == .json)
    #expect(LanguageDetector.detect(path: "notes", contents: "[not valid json]") == .plainText)
}

@Test func typedContentDetectsCommonWritingAndProgrammingLanguages() {
    #expect(
        LanguageDetector.detect(path: "", contents: "# Launch notes\n\n- [ ] Ship Clip")
            == .markdown
    )
    #expect(
        LanguageDetector.detect(
            path: "", contents: "import SwiftUI\n\n@main struct ClipApp: App {}")
            == .swift
    )
    #expect(
        LanguageDetector.detect(path: "", contents: "def render_clip():\n    return True")
            == .python)
    #expect(
        LanguageDetector.detect(
            path: "",
            contents: "# Build the card\ndef render_clip():\n    return True"
        ) == .python
    )
    #expect(
        LanguageDetector.detect(path: "", contents: "SELECT name FROM assets WHERE kind = 1")
            == .sql
    )
    #expect(
        LanguageDetector.detect(
            path: "", contents: "interface Clip { name: string }\nconst x: string = 'a'")
            == .typescript
    )
    #expect(
        LanguageDetector.detect(path: "", contents: "title: Clip\nready: true") == .yaml
    )
    #expect(
        LanguageDetector.detect(path: "", contents: "[package]\nname = \"clip\"") == .toml
    )
}

@Test func goProgramIsNotMistakenForSwift() {
    let source = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(1)\n}\n"
    #expect(LanguageDetector.detect(path: "", contents: source) == .go)
}

@Test func fileNamesFollowTheirLanguage() {
    #expect(LanguageDetector.fileName("Untitled.txt", matching: .go) == "Untitled.go")
    #expect(LanguageDetector.fileName("solver", matching: .python) == "solver.py")
    #expect(LanguageDetector.fileName("solver.py", matching: .python) == "solver.py")
    #expect(LanguageDetector.fileName("header.h", matching: .c) == "header.h")
    #expect(LanguageDetector.fileName("config.yml", matching: .yaml) == "config.yml")
    #expect(LanguageDetector.fileName("notes.md", matching: .rust) == "notes.rs")
    #expect(LanguageDetector.fileName("v1.2", matching: .python) == "v1.2.py")
    #expect(LanguageDetector.fileName("script.sh", matching: .plainText) == "script.txt")
}

@Test func everyLanguageHasAnExtensionThatMapsBackToIt() {
    for language in LanguageID.treeSitterGrammars + [.plainText] {
        let ext = LanguageDetector.preferredExtension(for: language)
        #expect(LanguageDetector.language(forExtension: ext) == language, "\(language.rawValue)")
    }
}
