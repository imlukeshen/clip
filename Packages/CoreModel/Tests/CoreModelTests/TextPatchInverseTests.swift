import CoreModel
import Testing

@Test func textPatchAndInverseRestoreIdentityAcrossOneThousandRandomSequences() throws {
    var random = TextRandom(seed: 0x7E27_F11E)

    for sequence in 0..<1_000 {
        let original = try TextDocument(
            id: DocumentID(rawValue: "text-\(sequence)"),
            files: [
                TextFile(
                    id: FileID(rawValue: "file-\(sequence)-root"),
                    relativePath: "main-\(sequence).tex",
                    language: .latex
                )
            ]
        )
        var document = original
        var inverses: [TextPatch] = []

        for step in 0..<random.int(in: 3...14) {
            let patch = randomPatch(
                sequence: sequence,
                step: step,
                document: document,
                random: &random
            )
            inverses.append(try document.apply(patch))
        }

        for inverse in inverses.reversed() {
            _ = try document.apply(inverse)
        }
        #expect(document == original, "Text sequence \(sequence) did not restore identity")
    }
}

@Test func textPatchRejectsInvalidMutationTransactionally() throws {
    let fileID = FileID(rawValue: "root")
    var document = try TextDocument(files: [TextFile(id: fileID, relativePath: "main.md")])
    let original = document
    do {
        _ = try document.apply(.setMainFile(FileID(rawValue: "missing")))
        Issue.record("Expected the main file to be rejected")
    } catch {
        #expect(error as? TextDocumentError == .mainFileNotFound(FileID(rawValue: "missing")))
    }
    #expect(document == original)
}

@Test func textPatchRejectsDuplicatePathTransactionally() throws {
    var document = try TextDocument(
        files: [TextFile(id: FileID(rawValue: "a"), relativePath: "shared.tex")]
    )
    let original = document
    do {
        _ = try document.apply(
            .addFile(TextFile(id: FileID(rawValue: "b"), relativePath: "shared.tex"), atIndex: 1)
        )
        Issue.record("Expected the duplicate path to be rejected")
    } catch {
        #expect(error as? TextDocumentError == .duplicatePath("shared.tex"))
    }
    #expect(document == original)
}

private func randomPatch(
    sequence: Int,
    step: Int,
    document: TextDocument,
    random: inout TextRandom
) -> TextPatch {
    let languages: [LanguageID] = [.plainText, .swift, .latex, .markdown, .python]
    switch random.int(in: 0...5) {
    case 0:
        return .addFile(
            TextFile(
                id: FileID(rawValue: "file-\(sequence)-\(step)"),
                relativePath: "added-\(sequence)-\(step).txt",
                language: languages[random.int(in: 0...(languages.count - 1))]
            ),
            atIndex: random.int(in: 0...document.files.count)
        )
    case 1 where canRemoveFile(from: document):
        // Removing the designated main file would leave `mainFileID` dangling and
        // fail validation — the model requires clearing it first, so the caller
        // (and this generator) only ever removes a non-main file, and never the
        // last one, so later cases always have a file to index.
        let removable = document.files.filter { $0.id != document.mainFileID }
        return .removeFile(removable[random.int(in: 0...(removable.count - 1))].id)
    case 2:
        let file = document.files[random.int(in: 0...(document.files.count - 1))]
        return .setLanguage(
            file.id,
            languages[random.int(in: 0...(languages.count - 1))],
            explicit: random.bool()
        )
    case 3:
        let id = random.bool() ? document.files[0].id : nil
        return .setMainFile(id)
    case 4:
        return .setSettings(
            EditorSettings(
                softWrap: random.bool(),
                tabWidth: random.int(in: 1...16),
                fontSize: random.bool() ? 13 : 15,
                showInvisibles: random.bool()
            )
        )
    default:
        let file = document.files[random.int(in: 0...(document.files.count - 1))]
        return .renameFile(file.id, "renamed-\(sequence)-\(step).txt")
    }
}

/// A file is removable only when another file exists to hold `mainFileID` and
/// the removed file is not the designated main file — otherwise removal would
/// leave `mainFileID` dangling and the `addFile` inverse could not restore it.
private func canRemoveFile(from document: TextDocument) -> Bool {
    document.files.count > 1 && document.files.contains { $0.id != document.mainFileID }
}

private struct TextRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func bool() -> Bool { next().isMultiple(of: 2) }
}
