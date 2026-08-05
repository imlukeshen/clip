import CoreModel
import Foundation
import Testing

@testable import TextEngine

@Test func markdownDocumentBuildsAStableTypedBlockTree() throws {
    let source = """
        # Plan
        - [ ] Ship **Clip**
          - nested
        > Keep exact source
        """
    let first = MarkdownBlockDocumentEngine.reconcile(source: source)

    #expect(
        first.blocks.map(\.kind) == [
            .heading(level: 1),
            .taskItem(isCompleted: false),
            .bulletedListItem,
            .quote,
        ])
    #expect(first.blocks[2].parentID == first.blocks[1].id)
    #expect(first.blocks[1].childIDs == [first.blocks[2].id])
    #expect(first.blocks[1].inlineSpans.map(\.kind) == [.strong])

    let edited = source.replacingOccurrences(of: "Ship", with: "Launch")
    let second = MarkdownBlockDocumentEngine.reconcile(source: edited, with: first)
    #expect(second.revision == first.revision + 1)
    #expect(second.blocks.map(\.id) == first.blocks.map(\.id))
    #expect(second.source == edited)
}

@Test func markdownDocumentPreservesUnknownSourceAndUTF16Ranges() throws {
    let source = """
        Emoji 👩🏽‍💻 and [Clip](https://example.com/a_(b))
        \\*literal markers\\*
        <custom-block data-preserve="yes" />
        """
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    #expect(snapshot.source == source)
    #expect(snapshot.blocks.count == 3)
    let link = try #require(
        snapshot.blocks[0].inlineSpans.first { span in
            if case .link = span.kind { return true }
            return false
        }
    )
    #expect(link.kind == .link(destination: "https://example.com/a_(b)"))
    #expect((source as NSString).substring(with: link.contentRange) == "Clip")
    #expect(snapshot.blocks[1].inlineSpans.isEmpty)

    let emojiLocation = (source as NSString).range(of: "👩🏽‍💻").location
    #expect(snapshot.block(containingUTF16: emojiLocation)?.id == snapshot.blocks[0].id)
}

@Test func markdownInlineParserHandlesNestedCommonMarkFormatting() throws {
    let source = "Read [**Clip _docs_**](https://example.com/a_(b)) and ``a `tick` here``."
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    let block = try #require(snapshot.blocks.first)

    #expect(block.inlineSpans.contains { $0.kind == .strong })
    #expect(block.inlineSpans.contains { $0.kind == .emphasis })
    #expect(block.inlineSpans.contains { $0.kind == .code })
    let link = try #require(
        block.inlineSpans.first { span in
            if case .link = span.kind { return true }
            return false
        }
    )
    #expect(link.kind == .link(destination: "https://example.com/a_(b)"))
    #expect((source as NSString).substring(with: link.contentRange) == "**Clip _docs_**")
    #expect(
        block.inlineSpans.flatMap(\.syntaxRanges).allSatisfy {
            $0.location >= 0 && NSMaxRange($0) <= (source as NSString).length
        })
}

@Test func markdownInlineParserUsesWholeDocumentContextForReferences() throws {
    let source = """
        Read [Clip][docs] and `$literal$`, then render $x + y$.

        [docs]: https://example.com/docs
        """
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    let first = try #require(snapshot.blocks.first)
    let link = try #require(
        first.inlineSpans.first { span in
            if case .link = span.kind { return true }
            return false
        }
    )

    #expect(link.kind == .link(destination: "https://example.com/docs"))
    #expect((source as NSString).substring(with: link.contentRange) == "Clip")
    #expect(first.inlineSpans.filter { $0.kind == .code }.count == 1)
    #expect(first.inlineSpans.filter { $0.kind == .math }.count == 1)
    let math = try #require(first.inlineSpans.first { $0.kind == .math })
    #expect((source as NSString).substring(with: math.contentRange) == "x + y")
}

@Test func markdownInlineParserMapsMultilineCommonMarkBackToBlocks() throws {
    let source = "Start *formatting across\nphysical lines* safely"
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)

    #expect(snapshot.blocks.count == 2)
    for block in snapshot.blocks {
        let emphasis = try #require(block.inlineSpans.first { $0.kind == .emphasis })
        #expect(NSIntersectionRange(emphasis.contentRange, block.contentRange).length > 0)
        #expect(NSMaxRange(emphasis.contentRange) <= NSMaxRange(block.contentRange))
    }
}

@Test func markdownInlineCoordinatesRemainUTF16CorrectAcrossUnicodeLines() throws {
    let source = "Emoji 👩🏽‍💻 first\nThen [Clip][docs]\n\n[docs]: https://example.com"
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    let link = try #require(
        snapshot.blocks[1].inlineSpans.first { span in
            if case .link = span.kind { return true }
            return false
        }
    )

    #expect((source as NSString).substring(with: link.contentRange) == "Clip")
    #expect(link.kind == .link(destination: "https://example.com"))
}

@Test func markdownInlineMathDoesNotLeakIntoLinksOrCode() {
    let source = "`$code$` [$label$](https://example.com/$destination$) and $math$"
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    let spans = snapshot.blocks[0].inlineSpans

    #expect(spans.filter { $0.kind == .code }.count == 1)
    #expect(
        spans.filter { span in
            if case .link = span.kind { return true }
            return false
        }.count == 1
    )
    #expect(spans.filter { $0.kind == .math }.count == 1)
}

@Test func markdownIncrementalEditRefreshesReferenceDefinitions() throws {
    let source = "Read [Clip][docs]\n\n[docs]: https://example.com/old"
    let first = MarkdownBlockDocumentEngine.reconcile(source: source)
    let oldRange = (source as NSString).range(of: "https://example.com/old")
    let destination = "https://example.com/new"
    let updatedSource = (source as NSString).replacingCharacters(
        in: oldRange,
        with: destination
    )
    let second = MarkdownBlockDocumentEngine.reconcile(
        source: updatedSource,
        with: first,
        edit: SyntaxEdit(
            previousRange: oldRange,
            currentRange: NSRange(
                location: oldRange.location,
                length: (destination as NSString).length
            )
        )
    )
    let link = try #require(
        second.blocks[0].inlineSpans.first { span in
            if case .link = span.kind { return true }
            return false
        }
    )

    #expect(link.kind == .link(destination: destination))
}

@Test func markdownIncrementalEditKeepsMultilineInlineFormatting() throws {
    let source = "Start *formatting across\nphysical lines* safely"
    let first = MarkdownBlockDocumentEngine.reconcile(source: source)
    let oldRange = (source as NSString).range(of: "physical")
    let replacement = "multiple physical"
    let updatedSource = (source as NSString).replacingCharacters(
        in: oldRange,
        with: replacement
    )
    let second = MarkdownBlockDocumentEngine.reconcile(
        source: updatedSource,
        with: first,
        edit: SyntaxEdit(
            previousRange: oldRange,
            currentRange: NSRange(
                location: oldRange.location,
                length: (replacement as NSString).length
            )
        )
    )

    #expect(second.blocks.count == 2)
    #expect(second.blocks.allSatisfy { $0.inlineSpans.contains { $0.kind == .emphasis } })
}

@Test func markdownDocumentUnderstandsLongAndTildeFencesPerBlock() {
    let source = """
        ````swift
        let fence = "```"
        ````
        ~~~python
        print("Clip")
        ~~~
        """
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    #expect(snapshot.blocks.count == 2)
    #expect(
        snapshot.blocks.map(\.kind) == [
            .fencedCode(language: .swift),
            .fencedCode(language: .python),
        ])
    #expect(snapshot.blocks.allSatisfy { $0.inlineSpans.isEmpty })
}

@Test func markdownTablesRequireASeparatorRowInsteadOfAnyPipeCharacter() {
    let source = """
        A | B
        --- | ---
        one | two

        This paragraph uses A | B without making a table.
        """
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    #expect(snapshot.blocks.prefix(3).allSatisfy { $0.kind == .table })
    #expect(snapshot.blocks[4].kind == .paragraph)
}

@Test func markdownTransactionsAreAtomicAndRejectStaleRevisions() throws {
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: "One\nTwo\nThree\n")
    let secondID = snapshot.blocks[1].id
    let updated = try MarkdownBlockDocumentEngine.apply(
        MarkdownDocumentTransaction(
            baseRevision: snapshot.revision,
            operations: [
                .replaceBlock(id: secondID, source: "Changed"),
                .insertBlock(after: secondID, source: "Inserted"),
            ]
        ),
        to: snapshot
    )
    #expect(updated.source == "One\nChanged\nInserted\nThree\n")
    #expect(updated.blocks[1].id == secondID)

    #expect(throws: MarkdownDocumentError.self) {
        try MarkdownBlockDocumentEngine.apply(
            MarkdownDocumentTransaction(
                baseRevision: snapshot.revision,
                operations: [.deleteBlocks(ids: [snapshot.blocks[0].id])]
            ),
            to: updated
        )
    }

    #expect(throws: MarkdownDocumentError.self) {
        try MarkdownBlockDocumentEngine.apply(
            MarkdownDocumentTransaction(
                baseRevision: snapshot.revision,
                operations: [
                    .deleteBlocks(ids: [snapshot.blocks[0].id]),
                    .replaceBlock(id: snapshot.blocks[0].id, source: "Duplicate"),
                ]
            ),
            to: snapshot
        )
    }
    #expect(snapshot.source == "One\nTwo\nThree\n")
}

@Test func markdownTransactionsOrderSamePointReplacementBeforeInsertion() throws {
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: "Old\nNext")
    let oldID = snapshot.blocks[0].id
    let updated = try MarkdownBlockDocumentEngine.apply(
        MarkdownDocumentTransaction(
            baseRevision: snapshot.revision,
            operations: [
                .replaceBlock(id: oldID, source: "Changed"),
                .insertBlock(after: nil, source: "Inserted"),
            ]
        ),
        to: snapshot
    )

    #expect(updated.source == "Inserted\nChanged\nNext")
    #expect(updated.blocks[1].id == oldID)

    #expect(throws: MarkdownDocumentError.self) {
        try MarkdownBlockDocumentEngine.apply(
            MarkdownDocumentTransaction(
                baseRevision: snapshot.revision,
                operations: [
                    .replaceText(range: NSRange(location: 0, length: 3), replacement: "New"),
                    .replaceText(range: NSRange(location: 1, length: 0), replacement: "x"),
                ]
            ),
            to: snapshot
        )
    }
}

@Test func markdownTransactionsKeepDuplicateBlockIdentities() throws {
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: "Same\nSame\nTail")
    let updated = try MarkdownBlockDocumentEngine.apply(
        MarkdownDocumentTransaction(
            baseRevision: snapshot.revision,
            operations: [
                .insertBlock(after: snapshot.blocks[0].id, source: "Same")
            ]
        ),
        to: snapshot
    )

    #expect(updated.source == "Same\nSame\nSame\nTail")
    #expect(updated.blocks[0].id == snapshot.blocks[0].id)
    #expect(updated.blocks[2].id == snapshot.blocks[1].id)
    #expect(updated.blocks[3].id == snapshot.blocks[2].id)
    #expect(!snapshot.blocks.map(\.id).contains(updated.blocks[1].id))
}

@Test func markdownFullReconcileUsesEditRangeToKeepDuplicateBlockIdentities() throws {
    let source = "Same\nSame\nTail"
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    let inserted = "Same\n"
    let updated = MarkdownBlockDocumentEngine.reconcile(
        source: inserted + source,
        with: snapshot,
        edit: SyntaxEdit(
            previousRange: NSRange(location: 0, length: 0),
            currentRange: NSRange(location: 0, length: (inserted as NSString).length)
        )
    )

    #expect(updated.blocks.dropFirst().map(\.id) == snapshot.blocks.map(\.id))
    #expect(!snapshot.blocks.map(\.id).contains(updated.blocks[0].id))
}

@Test func markdownBlockMovesDoNotDuplicateOrLoseSource() throws {
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: "First\nSecond\nThird\n")
    let moved = try MarkdownBlockDocumentEngine.apply(
        MarkdownDocumentTransaction(
            baseRevision: snapshot.revision,
            operations: [
                .moveBlock(id: snapshot.blocks[2].id, after: snapshot.blocks[0].id)
            ]
        ),
        to: snapshot
    )
    #expect(moved.source == "First\nThird\nSecond\n")
    #expect(Set(moved.blocks.map(\.id)) == Set(snapshot.blocks.map(\.id)))
}

@Test func markdownBlockMovesKeepTheWholeChildSubtree() throws {
    let snapshot = MarkdownBlockDocumentEngine.reconcile(
        source: "- Parent\n  - Child\nSibling"
    )
    let moved = try MarkdownBlockDocumentEngine.apply(
        MarkdownDocumentTransaction(
            baseRevision: snapshot.revision,
            operations: [
                .moveBlock(id: snapshot.blocks[0].id, after: snapshot.blocks[2].id)
            ]
        ),
        to: snapshot
    )

    #expect(moved.source == "Sibling\n- Parent\n  - Child\n")
    #expect(
        moved.blocks.prefix(3).map(\.id) == [
            snapshot.blocks[2].id,
            snapshot.blocks[0].id,
            snapshot.blocks[1].id,
        ])
    #expect(moved.blocks[2].parentID == moved.blocks[1].id)
}

@Test func markdownBlockMovesTrailingEmptyBlockToTheStartWithoutCorruptingIDs() throws {
    for ending in ["\n", "\r\n", "\r"] {
        let snapshot = MarkdownBlockDocumentEngine.reconcile(
            source: "First\(ending)Second\(ending)"
        )
        let trailing = try #require(snapshot.blocks.last)
        let moved = try MarkdownBlockDocumentEngine.apply(
            MarkdownDocumentTransaction(
                baseRevision: snapshot.revision,
                operations: [.moveBlock(id: trailing.id, after: nil)]
            ),
            to: snapshot
        )

        #expect(moved.source == "\(ending)First\(ending)Second")
        #expect(moved.blocks.map(\.kind) == [.empty, .paragraph, .paragraph])
        #expect(
            moved.blocks.map(\.id) == [
                trailing.id,
                snapshot.blocks[0].id,
                snapshot.blocks[1].id,
            ])
        #expect(Set(moved.blocks.map(\.id)).count == moved.blocks.count)
    }
}

@Test func markdownBlockMovesAnyRealBlockAfterTheTrailingEmptyBlock() throws {
    for sourceID in [0, 1] {
        let snapshot = MarkdownBlockDocumentEngine.reconcile(source: "First\nSecond\n")
        let trailing = try #require(snapshot.blocks.last)
        let moved = try MarkdownBlockDocumentEngine.apply(
            MarkdownDocumentTransaction(
                baseRevision: snapshot.revision,
                operations: [
                    .moveBlock(id: snapshot.blocks[sourceID].id, after: trailing.id)
                ]
            ),
            to: snapshot
        )
        let remainingID = snapshot.blocks[sourceID == 0 ? 1 : 0].id

        #expect(
            moved.source
                == (sourceID == 0 ? "Second\n\nFirst" : "First\n\nSecond")
        )
        #expect(moved.blocks.map(\.kind) == [.paragraph, .empty, .paragraph])
        #expect(
            moved.blocks.map(\.id) == [
                remainingID,
                trailing.id,
                snapshot.blocks[sourceID].id,
            ])
        #expect(Set(moved.blocks.map(\.id)).count == moved.blocks.count)
    }
}

@Test func markdownBlockMovesAChildSubtreeAfterTheTrailingEmptyBlock() throws {
    let snapshot = MarkdownBlockDocumentEngine.reconcile(
        source: "- Parent\n  - Child\nSibling\n"
    )
    let trailing = try #require(snapshot.blocks.last)
    let moved = try MarkdownBlockDocumentEngine.apply(
        MarkdownDocumentTransaction(
            baseRevision: snapshot.revision,
            operations: [
                .moveBlock(id: snapshot.blocks[0].id, after: trailing.id)
            ]
        ),
        to: snapshot
    )

    #expect(moved.source == "Sibling\n\n- Parent\n  - Child")
    #expect(
        moved.blocks.map(\.id) == [
            snapshot.blocks[2].id,
            trailing.id,
            snapshot.blocks[0].id,
            snapshot.blocks[1].id,
        ])
    #expect(moved.blocks[3].parentID == moved.blocks[2].id)
    #expect(Set(moved.blocks.map(\.id)).count == moved.blocks.count)
}

@Test func markdownDocumentRepresentsTheTrailingEmptyBlock() throws {
    let source = "One\n"
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    let trailing = try #require(snapshot.blocks.last)

    #expect(snapshot.blocks.count == 2)
    #expect(trailing.kind == .empty)
    #expect(trailing.sourceRange == NSRange(location: (source as NSString).length, length: 0))
    #expect(snapshot.block(containingUTF16: (source as NSString).length)?.id == trailing.id)
}

@Test func markdownTransactionsDeleteTrailingEmptyBlocksForEveryLineEnding() throws {
    for source in ["One\n", "One\r\n", "One\r"] {
        let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
        let trailing = try #require(snapshot.blocks.last)
        let updated = try MarkdownBlockDocumentEngine.apply(
            MarkdownDocumentTransaction(
                baseRevision: snapshot.revision,
                operations: [.deleteBlocks(ids: [trailing.id])]
            ),
            to: snapshot
        )

        #expect(updated.source == "One")
        #expect(updated.blocks.count == 1)
        #expect(updated.blocks[0].id == snapshot.blocks[0].id)
        #expect(!updated.blocks.map(\.id).contains(trailing.id))
    }
}

@Test func markdownTransactionsInsertAfterTrailingEmptyBlocksWithoutReusingIDs() throws {
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: "One\n")
    let trailing = try #require(snapshot.blocks.last)
    let updated = try MarkdownBlockDocumentEngine.apply(
        MarkdownDocumentTransaction(
            baseRevision: snapshot.revision,
            operations: [.insertBlock(after: trailing.id, source: "Added")]
        ),
        to: snapshot
    )

    #expect(updated.source == "One\n\nAdded\n")
    #expect(updated.blocks.map(\.kind) == [.paragraph, .empty, .paragraph, .empty])
    #expect(updated.blocks[1].id == trailing.id)
    #expect(Set(updated.blocks.map(\.id)).count == updated.blocks.count)
}

@Test func markdownTransactionsCanDeleteThenInsertAtTheTrailingEmptyBoundary() throws {
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: "One\n")
    let trailing = try #require(snapshot.blocks.last)
    let updated = try MarkdownBlockDocumentEngine.apply(
        MarkdownDocumentTransaction(
            baseRevision: snapshot.revision,
            operations: [
                .insertBlock(after: trailing.id, source: "Added"),
                .deleteBlocks(ids: [trailing.id]),
            ]
        ),
        to: snapshot
    )

    #expect(updated.source == "One\nAdded\n")
    #expect(!updated.blocks.map(\.id).contains(trailing.id))
    #expect(Set(updated.blocks.map(\.id)).count == updated.blocks.count)
}

@Test func markdownBlockOperationsPreserveCRLFLineEndings() throws {
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: "One\r\nTwo\r\n")
    let updated = try MarkdownBlockDocumentEngine.apply(
        MarkdownDocumentTransaction(
            baseRevision: snapshot.revision,
            operations: [
                .replaceBlock(id: snapshot.blocks[1].id, source: "Changed"),
                .insertBlock(after: snapshot.blocks[1].id, source: "Added"),
            ]
        ),
        to: snapshot
    )

    #expect(updated.source == "One\r\nChanged\r\nAdded\r\n")
    #expect(!updated.source.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
}

@Test func markdownDocumentKeepsLargeNotesInteractive() {
    let source = (0..<20_000).map { "Paragraph \($0) with ordinary prose." }
        .joined(separator: "\n")
    let clock = ContinuousClock()
    let start = clock.now
    let snapshot = MarkdownBlockDocumentEngine.reconcile(source: source)
    let elapsed = start.duration(to: clock.now)

    #expect(snapshot.blocks.count == 20_000)
    #expect(elapsed < .seconds(3))
}

@Test func markdownDocumentReconcilesOneTypedBlockIncrementally() throws {
    let source = (0..<20_000).map { "Paragraph \($0) with ordinary prose." }
        .joined(separator: "\n")
    let first = MarkdownBlockDocumentEngine.reconcile(source: source)
    let oldRange = (source as NSString).range(of: "Paragraph 10000")
    let replacement = "Updated paragraph 10000"
    let updatedSource = (source as NSString).replacingCharacters(
        in: oldRange,
        with: replacement
    )
    let edit = SyntaxEdit(
        previousRange: oldRange,
        currentRange: NSRange(
            location: oldRange.location,
            length: (replacement as NSString).length
        )
    )
    let clock = ContinuousClock()
    let start = clock.now
    let second = MarkdownBlockDocumentEngine.reconcile(
        source: updatedSource,
        with: first,
        edit: edit
    )
    let elapsed = start.duration(to: clock.now)

    #expect(second.blocks.map(\.id) == first.blocks.map(\.id))
    #expect(second.blocks[10_000].source.contains("Updated paragraph"))
    let lastBlock = try #require(second.blocks.last)
    #expect(NSMaxRange(lastBlock.sourceRange) == updatedSource.utf16.count)
    #expect(elapsed < .seconds(1))
}

@Test func markdownDocumentTreatsColumnOneAsTheFollowingBlockBoundary() {
    let line = "Repeated paragraph."
    let source = Array(repeating: line, count: 20_000).joined(separator: "\n")
    let first = MarkdownBlockDocumentEngine.reconcile(source: source)
    let location = (line as NSString).length + 1
    let insertion = "Updated "
    let updatedSource = (source as NSString).replacingCharacters(
        in: NSRange(location: location, length: 0),
        with: insertion
    )
    let clock = ContinuousClock()
    let start = clock.now
    let second = MarkdownBlockDocumentEngine.reconcile(
        source: updatedSource,
        with: first,
        edit: SyntaxEdit(
            previousRange: NSRange(location: location, length: 0),
            currentRange: NSRange(
                location: location,
                length: (insertion as NSString).length
            )
        )
    )
    let elapsed = start.duration(to: clock.now)

    #expect(second.blocks.map(\.id) == first.blocks.map(\.id))
    #expect(second.blocks[1].source.hasPrefix(insertion))
    #expect(elapsed < .seconds(1))
}

@Test func markdownIncrementalTypingDoesNotReparseAnUnrelatedRichDocument() {
    let ordinaryLines = (0..<20_000).map { "Paragraph \($0)." }
    let source = (["**Rich heading**"] + ordinaryLines).joined(separator: "\n")
    let first = MarkdownBlockDocumentEngine.reconcile(source: source)
    let target = "Paragraph 10000."
    let location = (source as NSString).range(of: target).location
    let insertion = "Updated "
    let updatedSource = (source as NSString).replacingCharacters(
        in: NSRange(location: location, length: 0),
        with: insertion
    )
    let clock = ContinuousClock()
    let start = clock.now
    let second = MarkdownBlockDocumentEngine.reconcile(
        source: updatedSource,
        with: first,
        edit: SyntaxEdit(
            previousRange: NSRange(location: location, length: 0),
            currentRange: NSRange(
                location: location,
                length: (insertion as NSString).length
            )
        )
    )
    let elapsed = start.duration(to: clock.now)

    #expect(second.blocks[10_001].source.hasPrefix(insertion))
    #expect(second.blocks[0].inlineSpans.contains { $0.kind == .strong })
    #expect(elapsed < .seconds(1))
}
