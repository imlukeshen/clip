import Foundation
import Testing

@testable import ReelAppCore

@Test func texProjectFolderLoadsSourcesBibliographyAndReferencedResources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-tex-project-loader-\(UUID().uuidString)",
        isDirectory: true
    )
    let chapters = root.appendingPathComponent("chapters", isDirectory: true)
    try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("\\documentclass{article}\\input{chapters/one}".utf8)
        .write(to: root.appendingPathComponent("main.tex"))
    try Data("Chapter".utf8).write(to: chapters.appendingPathComponent("one.tex"))
    try Data("@book{clip}".utf8).write(to: root.appendingPathComponent("refs.bib"))
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("figure.png"))

    let project = try TeXProjectFolderLoader.load(rootURL: root)

    #expect(project.textFiles.keys.contains("main.tex"))
    #expect(project.textFiles.keys.contains("chapters/one.tex"))
    #expect(project.textFiles.keys.contains("refs.bib"))
    #expect(project.fileURLs.keys.contains("figure.png"))
}

@Test func openingAnIncludedFileFindsItsAncestorMainProject() throws {
    let boundary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-tex-project-boundary-\(UUID().uuidString)",
        isDirectory: true
    )
    let projectRoot = boundary.appendingPathComponent("Paper", isDirectory: true)
    let chapters = projectRoot.appendingPathComponent("chapters", isDirectory: true)
    try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: boundary) }
    try Data("\\documentclass{article}\\input{chapters/one}".utf8)
        .write(to: projectRoot.appendingPathComponent("main.tex"))
    let included = chapters.appendingPathComponent("one.tex")
    try Data("Chapter".utf8).write(to: included)

    let project = try TeXProjectFolderLoader.loadProject(
        containing: included,
        boundaryURL: boundary
    )

    #expect(project.rootURL == projectRoot)
    #expect(project.textFiles.keys.contains("chapters/one.tex"))
}
