import Foundation
import Testing

@testable import TextEngine

@Test func workspaceStagesLocalMainFileContainingAColon() throws {
    let fixture = try TeXWorkspaceFixture(mainFileName: "launch:final.tex")
    defer { fixture.remove() }

    let workspace = try TeXWorkspaceSandbox.prepare(TeXJob(mainFile: fixture.mainFile))
    defer { workspace.remove() }

    #expect(workspace.mainRelativePath == "launch:final.tex")
    #expect(
        FileManager.default.fileExists(
            atPath: workspace.source.appendingPathComponent("launch:final.tex").path
        )
    )
}

@Test func workspaceStillRejectsATraversalOverride() throws {
    let fixture = try TeXWorkspaceFixture(mainFileName: "main.tex")
    defer { fixture.remove() }

    #expect(throws: TeXEngineError.unsafeProjectEntry("../escape.tex")) {
        _ = try TeXWorkspaceSandbox.prepare(
            TeXJob(
                mainFile: fixture.mainFile,
                sourceOverrides: ["../escape.tex": Data("escaped".utf8)]
            )
        )
    }
}

private struct TeXWorkspaceFixture {
    let root: URL
    let mainFile: URL

    init(mainFileName: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-tex-workspace-test-\(UUID().uuidString)",
            isDirectory: true
        )
        mainFile = root.appendingPathComponent(mainFileName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("\\documentclass{article}\n".utf8).write(to: mainFile)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
