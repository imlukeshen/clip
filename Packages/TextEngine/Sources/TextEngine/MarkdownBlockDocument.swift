import CoreModel
import Foundation
import Markdown

/// A durable identity for one semantic Markdown block.
///
/// The ID is intentionally independent of the block's source range. Editing text
/// before a block therefore does not invalidate selections, pending operations,
/// or future collaboration metadata that point at that block.
public struct MarkdownBlockID: RawRepresentable, Sendable, Hashable, Codable {
    public var rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Semantic block types understood by Clip's Markdown document engine.
public enum MarkdownBlockKind: Sendable, Hashable {
    case paragraph
    case heading(level: Int)
    case bulletedListItem
    case numberedListItem(ordinal: Int)
    case taskItem(isCompleted: Bool)
    case quote
    case fencedCode(language: LanguageID)
    case math
    case divider
    case table
    case empty
    case raw
}

/// Inline formatting is stored independently from block structure, matching a
/// rich-text-run model while retaining exact Markdown source ranges for export.
public enum MarkdownInlineKind: Sendable, Hashable {
    case strong
    case emphasis
    case strikethrough
    case code
    case link(destination: String)
    case math
}

public struct MarkdownInlineSpan: Sendable, Hashable {
    public var kind: MarkdownInlineKind
    /// The user-visible content, excluding Markdown delimiters.
    public var contentRange: NSRange
    /// Delimiters and destinations that are syntax rather than visible content.
    public var syntaxRanges: [NSRange]

    public init(
        kind: MarkdownInlineKind,
        contentRange: NSRange,
        syntaxRanges: [NSRange]
    ) {
        self.kind = kind
        self.contentRange = contentRange
        self.syntaxRanges = syntaxRanges
    }
}

/// One lossless Markdown block. `sourceRange` includes its line terminator so
/// deleting or moving a block cannot accidentally leave stale blank lines.
public struct MarkdownBlock: Sendable, Hashable, Identifiable {
    public var id: MarkdownBlockID
    public var kind: MarkdownBlockKind
    public var parentID: MarkdownBlockID?
    public var childIDs: [MarkdownBlockID]
    public var depth: Int
    public var sourceRange: NSRange
    public var contentRange: NSRange
    public var syntaxRanges: [NSRange]
    public var inlineSpans: [MarkdownInlineSpan]
    public var source: String

    public init(
        id: MarkdownBlockID,
        kind: MarkdownBlockKind,
        parentID: MarkdownBlockID? = nil,
        childIDs: [MarkdownBlockID] = [],
        depth: Int,
        sourceRange: NSRange,
        contentRange: NSRange,
        syntaxRanges: [NSRange],
        inlineSpans: [MarkdownInlineSpan],
        source: String
    ) {
        self.id = id
        self.kind = kind
        self.parentID = parentID
        self.childIDs = childIDs
        self.depth = depth
        self.sourceRange = sourceRange
        self.contentRange = contentRange
        self.syntaxRanges = syntaxRanges
        self.inlineSpans = inlineSpans
        self.source = source
    }
}

/// Immutable, revisioned state consumed by the AppKit bridge and persistence.
public struct MarkdownDocumentSnapshot: Sendable, Equatable {
    public var revision: UInt64
    public var source: String
    public var blocks: [MarkdownBlock]

    public init(revision: UInt64, source: String, blocks: [MarkdownBlock]) {
        self.revision = revision
        self.source = source
        self.blocks = blocks
    }

    public func block(containingUTF16 location: Int) -> MarkdownBlock? {
        guard !blocks.isEmpty else { return nil }
        let length = (source as NSString).length
        let safeLocation = min(max(location, 0), length)
        if safeLocation == length, let last = blocks.last,
            NSMaxRange(last.sourceRange) == length
        {
            return last
        }
        var lower = 0
        var upper = blocks.count - 1
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            let block = blocks[middle]
            if safeLocation < block.sourceRange.location {
                upper = middle - 1
            } else if safeLocation >= NSMaxRange(block.sourceRange) {
                lower = middle + 1
            } else {
                return block
            }
        }
        return nil
    }

    public func position(atUTF16 location: Int) -> MarkdownDocumentPosition? {
        guard let block = block(containingUTF16: location) else { return nil }
        let offset = min(
            max(location - block.contentRange.location, 0),
            block.contentRange.length
        )
        return MarkdownDocumentPosition(blockID: block.id, utf16Offset: offset)
    }

    public func utf16Location(for position: MarkdownDocumentPosition) -> Int? {
        guard let block = blocks.first(where: { $0.id == position.blockID }) else {
            return nil
        }
        return block.contentRange.location
            + min(max(position.utf16Offset, 0), block.contentRange.length)
    }

    public func sourceRange(for selection: MarkdownDocumentSelection) -> NSRange? {
        guard let anchor = utf16Location(for: selection.anchor),
            let head = utf16Location(for: selection.head)
        else { return nil }
        return NSRange(location: min(anchor, head), length: abs(head - anchor))
    }
}

/// A selection that remains meaningful when blocks before it move.
public struct MarkdownDocumentPosition: Sendable, Hashable {
    public var blockID: MarkdownBlockID
    public var utf16Offset: Int

    public init(blockID: MarkdownBlockID, utf16Offset: Int) {
        self.blockID = blockID
        self.utf16Offset = utf16Offset
    }
}

public struct MarkdownDocumentSelection: Sendable, Hashable {
    public var anchor: MarkdownDocumentPosition
    public var head: MarkdownDocumentPosition

    public init(anchor: MarkdownDocumentPosition, head: MarkdownDocumentPosition) {
        self.anchor = anchor
        self.head = head
    }
}

public enum MarkdownDocumentOperation: Sendable, Equatable {
    case replaceText(range: NSRange, replacement: String)
    case replaceBlock(id: MarkdownBlockID, source: String)
    case insertBlock(after: MarkdownBlockID?, source: String)
    case deleteBlocks(ids: [MarkdownBlockID])
    case moveBlock(id: MarkdownBlockID, after: MarkdownBlockID?)
}

/// A group of operations that must either all apply or all fail.
public struct MarkdownDocumentTransaction: Sendable, Equatable {
    public var baseRevision: UInt64
    public var operations: [MarkdownDocumentOperation]
    public var selectionBefore: MarkdownDocumentSelection?
    public var selectionAfter: MarkdownDocumentSelection?

    public init(
        baseRevision: UInt64,
        operations: [MarkdownDocumentOperation],
        selectionBefore: MarkdownDocumentSelection? = nil,
        selectionAfter: MarkdownDocumentSelection? = nil
    ) {
        self.baseRevision = baseRevision
        self.operations = operations
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
    }
}

public enum MarkdownDocumentError: Error, Sendable, Equatable {
    case staleRevision(expected: UInt64, actual: UInt64)
    case invalidRange(NSRange)
    case missingBlock(MarkdownBlockID)
    case duplicateBlockOperation(MarkdownBlockID)
}

extension MarkdownDocumentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .staleRevision(let expected, let actual):
            "The Markdown edit targets revision \(expected), but the document is at \(actual)."
        case .invalidRange:
            "The Markdown edit contains a range outside the document."
        case .missingBlock:
            "The Markdown edit refers to a block that no longer exists."
        case .duplicateBlockOperation:
            "The Markdown transaction changes the same block more than once."
        }
    }
}

/// Lossless block parsing, stable-ID reconciliation, and atomic transactions.
///
/// This is original Clip code based on public block-editor semantics. It keeps
/// exact source in every block so unsupported Markdown is never discarded.
public enum MarkdownBlockDocumentEngine {
    private struct SourceReplacement {
        var range: NSRange
        var replacement: String
        var order: Int
    }

    private struct PlannedBlockIdentity {
        var id: MarkdownBlockID
        var depth: Int
    }

    /// Parses source and retains IDs for unchanged or locally edited blocks.
    public static func reconcile(
        source: String,
        with previous: MarkdownDocumentSnapshot? = nil
    ) -> MarkdownDocumentSnapshot {
        reconcileFull(source: source, with: previous, edit: nil)
    }

    private static func reconcileFull(
        source: String,
        with previous: MarkdownDocumentSnapshot?,
        edit: SyntaxEdit?
    ) -> MarkdownDocumentSnapshot {
        if let previous, previous.source == source {
            return previous
        }

        var drafts = parse(source)
        reconcileIDs(
            in: &drafts,
            with: previous?.blocks ?? [],
            edit: edit,
            previousSourceLength: previous.map { ($0.source as NSString).length },
            sourceLength: (source as NSString).length
        )
        connectHierarchy(in: &drafts)
        let revision = previous.map { $0.revision &+ 1 } ?? 0
        return MarkdownDocumentSnapshot(revision: revision, source: source, blocks: drafts)
    }

    /// Reconciles a normal in-line typing edit without reparsing unrelated
    /// blocks. Structural edits that can affect neighboring blocks fall back to
    /// the lossless full parser.
    public static func reconcile(
        source: String,
        with previous: MarkdownDocumentSnapshot,
        edit: SyntaxEdit
    ) -> MarkdownDocumentSnapshot {
        guard previous.source != source else { return previous }
        let oldText = previous.source as NSString
        let newText = source as NSString
        guard edit.previousRange.location >= 0, edit.previousRange.length >= 0,
            edit.currentRange.location >= 0, edit.currentRange.length >= 0,
            NSMaxRange(edit.previousRange) <= oldText.length,
            NSMaxRange(edit.currentRange) <= newText.length
        else { return reconcileFull(source: source, with: previous, edit: edit) }
        guard
            let oldBlockIndex = blockIndex(
                containing: edit.previousRange,
                sourceLength: oldText.length,
                in: previous.blocks
            )
        else { return reconcileFull(source: source, with: previous, edit: edit) }

        let oldBlock = previous.blocks[oldBlockIndex]
        switch oldBlock.kind {
        case .fencedCode, .math, .table:
            return reconcileFull(source: source, with: previous, edit: edit)
        default:
            break
        }

        let oldFragment = oldText.substring(with: edit.previousRange)
        let newFragment = newText.substring(with: edit.currentRange)
        let structurallyUnsafe = "\n\r|"
        guard !oldFragment.contains(where: structurallyUnsafe.contains),
            !newFragment.contains(where: structurallyUnsafe.contains)
        else { return reconcileFull(source: source, with: previous, edit: edit) }

        let newLineRange = newText.lineRange(
            for: NSRange(location: edit.currentRange.location, length: 0)
        )
        let lineSource = newText.substring(with: newLineRange)
        guard !lineSource.contains("```"), !lineSource.contains("~~~"),
            !lineSource.contains("|"),
            lineSource.trimmingCharacters(in: .whitespacesAndNewlines) != "$$",
            newLineRange.location == oldBlock.sourceRange.location
        else { return reconcileFull(source: source, with: previous, edit: edit) }

        var parsed = parse(lineSource)
        if parsed.last?.sourceRange.length == 0,
            lineSource.hasSuffix("\n") || lineSource.hasSuffix("\r")
        {
            parsed.removeLast()
        }
        guard parsed.count == 1 else {
            return reconcileFull(source: source, with: previous, edit: edit)
        }
        parsed[0] = shifted(parsed[0], by: newLineRange.location)
        parsed[0].id = oldBlock.id

        let delta = newText.length - oldText.length
        var blocks = Array(previous.blocks[..<oldBlockIndex])
        blocks.append(parsed[0])
        blocks.append(
            contentsOf: previous.blocks[(oldBlockIndex + 1)...].map {
                shifted($0, by: delta)
            }
        )
        if requiresDocumentInlineRefresh(
            oldFragment: oldFragment,
            newFragment: newFragment,
            lineSource: lineSource,
            oldBlock: oldBlock,
            oldSource: oldText
        ) {
            attachInlineSpans(in: &blocks, source: source)
        }
        connectHierarchy(in: &blocks)
        return MarkdownDocumentSnapshot(
            revision: previous.revision &+ 1,
            source: source,
            blocks: blocks
        )
    }

    /// Finds the one block owned by an edit using half-open source ranges.
    /// A zero-width edit at a line boundary belongs to the block that starts
    /// there, while typing at a document without a trailing newline belongs to
    /// its final block.
    private static func blockIndex(
        containing range: NSRange,
        sourceLength: Int,
        in blocks: [MarkdownBlock]
    ) -> Int? {
        if range.length == 0 {
            if let index = blocks.firstIndex(where: {
                $0.sourceRange.location == range.location
            }) {
                return index
            }
            if let index = blocks.firstIndex(where: {
                range.location > $0.sourceRange.location
                    && range.location < NSMaxRange($0.sourceRange)
            }) {
                return index
            }
            if range.location == sourceLength {
                return blocks.indices.last
            }
            return nil
        }

        return blocks.firstIndex(where: {
            range.location >= $0.sourceRange.location
                && range.location < NSMaxRange($0.sourceRange)
                && NSMaxRange(range) <= NSMaxRange($0.sourceRange)
        })
    }

    /// Applies an operation batch against exactly one known revision.
    public static func apply(
        _ transaction: MarkdownDocumentTransaction,
        to snapshot: MarkdownDocumentSnapshot
    ) throws -> MarkdownDocumentSnapshot {
        guard transaction.baseRevision == snapshot.revision else {
            throw MarkdownDocumentError.staleRevision(
                expected: transaction.baseRevision,
                actual: snapshot.revision
            )
        }

        var replacements: [SourceReplacement] = []
        var touched: Set<MarkdownBlockID> = []
        let fullRange = NSRange(location: 0, length: (snapshot.source as NSString).length)
        let lineEnding = preferredLineEnding(in: snapshot.source)
        var identityPlan: [PlannedBlockIdentity]? =
            transaction.operations.contains { operation in
                if case .replaceText = operation { return true }
                return false
            }
            ? nil
            : snapshot.blocks.map {
                PlannedBlockIdentity(id: $0.id, depth: $0.depth)
            }

        func appendReplacement(_ range: NSRange, _ replacement: String) {
            replacements.append(
                SourceReplacement(
                    range: range,
                    replacement: replacement,
                    order: replacements.count
                )
            )
        }

        for operation in transaction.operations {
            switch operation {
            case .replaceText(let range, let replacement):
                guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= fullRange.length
                else { throw MarkdownDocumentError.invalidRange(range) }
                appendReplacement(range, replacement)

            case .replaceBlock(let id, let source):
                guard touched.insert(id).inserted else {
                    throw MarkdownDocumentError.duplicateBlockOperation(id)
                }
                guard let block = snapshot.blocks.first(where: { $0.id == id }) else {
                    throw MarkdownDocumentError.missingBlock(id)
                }
                let normalized = normalizedBlockSource(source, lineEnding: lineEnding)
                appendReplacement(block.sourceRange, normalized)
                replaceIdentity(id, with: normalized, in: &identityPlan)

            case .insertBlock(let after, let source):
                let location: Int
                let insertsAfterTrailingEmptyBlock: Bool
                if let after {
                    guard let index = snapshot.blocks.firstIndex(where: { $0.id == after }) else {
                        throw MarkdownDocumentError.missingBlock(after)
                    }
                    location = NSMaxRange(subtreeSourceRange(at: index, in: snapshot.blocks))
                    insertsAfterTrailingEmptyBlock = isTrailingEmptyBlock(
                        snapshot.blocks[index],
                        sourceLength: fullRange.length
                    )
                } else {
                    location = 0
                    insertsAfterTrailingEmptyBlock = false
                }
                let normalized = normalizedBlockSource(source, lineEnding: lineEnding)
                var insertion = insertionSource(
                    normalized,
                    at: location,
                    in: snapshot.source,
                    lineEnding: lineEnding
                )
                if insertsAfterTrailingEmptyBlock, !normalized.isEmpty {
                    insertion = lineEnding + insertion
                }
                appendReplacement(
                    NSRange(location: location, length: 0),
                    insertion
                )
                insertIdentities(from: normalized, after: after, in: &identityPlan)

            case .deleteBlocks(let ids):
                for id in ids {
                    guard touched.insert(id).inserted else {
                        throw MarkdownDocumentError.duplicateBlockOperation(id)
                    }
                    guard let block = snapshot.blocks.first(where: { $0.id == id }) else {
                        throw MarkdownDocumentError.missingBlock(id)
                    }
                    if isTrailingEmptyBlock(block, sourceLength: fullRange.length) {
                        if let lineEndingRange = trailingLineEndingRange(in: snapshot.source) {
                            appendReplacement(lineEndingRange, "")
                        }
                    } else {
                        appendReplacement(block.sourceRange, "")
                    }
                    deleteIdentity(id, in: &identityPlan)
                }

            case .moveBlock(let id, let after):
                guard touched.insert(id).inserted else {
                    throw MarkdownDocumentError.duplicateBlockOperation(id)
                }
                guard let blockIndex = snapshot.blocks.firstIndex(where: { $0.id == id }) else {
                    throw MarkdownDocumentError.missingBlock(id)
                }
                if after == id { continue }
                let movingBlock = snapshot.blocks[blockIndex]
                let movingRange = subtreeSourceRange(at: blockIndex, in: snapshot.blocks)
                let destination: Int
                let targetIsTrailingEmptyBlock: Bool
                if let after {
                    guard let targetIndex = snapshot.blocks.firstIndex(where: { $0.id == after })
                    else {
                        throw MarkdownDocumentError.missingBlock(after)
                    }
                    let targetRange = subtreeSourceRange(at: targetIndex, in: snapshot.blocks)
                    if rangesOverlap(targetRange, movingRange) { continue }
                    destination = NSMaxRange(targetRange)
                    targetIsTrailingEmptyBlock = isTrailingEmptyBlock(
                        snapshot.blocks[targetIndex],
                        sourceLength: fullRange.length
                    )
                } else {
                    destination = 0
                    targetIsTrailingEmptyBlock = false
                }

                let movingIsTrailingEmptyBlock = isTrailingEmptyBlock(
                    movingBlock,
                    sourceLength: fullRange.length
                )
                if destination == movingRange.location
                    || (destination == NSMaxRange(movingRange)
                        && !targetIsTrailingEmptyBlock)
                {
                    continue
                }

                // The final empty block is represented by the document's last
                // line ending rather than by a nonempty source range. Move that
                // terminator when the block itself moves so its durable ID still
                // describes an empty block in the resulting source.
                if movingIsTrailingEmptyBlock {
                    guard let endingRange = trailingLineEndingRange(in: snapshot.source) else {
                        continue
                    }
                    let ending = (snapshot.source as NSString).substring(with: endingRange)
                    appendReplacement(endingRange, "")
                    appendReplacement(
                        NSRange(location: destination, length: 0),
                        ending
                    )
                    moveIdentity(id, after: after, in: &identityPlan)
                    continue
                }

                let movingSource = normalizedBlockSource(
                    (snapshot.source as NSString).substring(with: movingRange),
                    lineEnding: lineEnding
                )
                appendReplacement(movingRange, "")

                if targetIsTrailingEmptyBlock,
                    let endingRange = trailingLineEndingRange(in: snapshot.source)
                {
                    // Moving after the synthetic EOF block turns it into a real
                    // blank block. Its existing terminator separates that blank
                    // block from the moved subtree; the moved subtree becomes
                    // the new unterminated end of the document.
                    let ending = (snapshot.source as NSString).substring(with: endingRange)
                    appendReplacement(
                        NSRange(location: destination, length: 0),
                        ending + removingTrailingLineEnding(from: movingSource)
                    )
                    moveIdentity(id, after: after, in: &identityPlan)
                    continue
                }

                appendReplacement(
                    NSRange(location: destination, length: 0),
                    insertionSource(
                        movingSource,
                        at: destination,
                        in: snapshot.source,
                        lineEnding: lineEnding
                    )
                )
                moveIdentity(id, after: after, in: &identityPlan)
            }
        }

        try validateNonOverlapping(replacements)
        let updated = NSMutableString(string: snapshot.source)
        for edit in replacements.sorted(by: replacementSort) {
            updated.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        var result = reconcile(source: updated as String, with: snapshot)
        if let identityPlan {
            let hasImplicitTrailingBlock =
                identityPlan.count + 1 == result.blocks.count
                && result.blocks.last.map {
                    isTrailingEmptyBlock(
                        $0,
                        sourceLength: (result.source as NSString).length
                    )
                } == true
            if identityPlan.count == result.blocks.count || hasImplicitTrailingBlock {
                for index in identityPlan.indices {
                    result.blocks[index].id = identityPlan[index].id
                }
                if hasImplicitTrailingBlock, let lastIndex = result.blocks.indices.last {
                    result.blocks[lastIndex].id = MarkdownBlockID()
                }
                connectHierarchy(in: &result.blocks)
            }
        }
        return result
    }

    private static func isTrailingEmptyBlock(
        _ block: MarkdownBlock,
        sourceLength: Int
    ) -> Bool {
        block.kind == .empty
            && block.sourceRange == NSRange(location: sourceLength, length: 0)
    }

    private static func trailingLineEndingRange(in source: String) -> NSRange? {
        let text = source as NSString
        guard text.length > 0 else { return nil }
        let lastLocation = text.length - 1
        switch text.character(at: lastLocation) {
        case 10:
            if lastLocation > 0, text.character(at: lastLocation - 1) == 13 {
                return NSRange(location: lastLocation - 1, length: 2)
            }
            return NSRange(location: lastLocation, length: 1)
        case 13:
            return NSRange(location: lastLocation, length: 1)
        default:
            return nil
        }
    }

    private static func removingTrailingLineEnding(from source: String) -> String {
        guard let range = trailingLineEndingRange(in: source) else { return source }
        return (source as NSString).substring(to: range.location)
    }

    private static func parse(_ source: String) -> [MarkdownBlock] {
        let text = source as NSString
        let lines = sourceLines(in: text)
        guard !lines.isEmpty else {
            return [
                MarkdownBlock(
                    id: MarkdownBlockID(),
                    kind: .empty,
                    depth: 0,
                    sourceRange: NSRange(location: 0, length: 0),
                    contentRange: NSRange(location: 0, length: 0),
                    syntaxRanges: [],
                    inlineSpans: [],
                    source: ""
                )
            ]
        }

        var result: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let body = text.substring(with: line.bodyRange)
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if let fence = openingFence(in: trimmed) {
                var endIndex = index
                while endIndex + 1 < lines.count {
                    endIndex += 1
                    let candidate = text.substring(with: lines[endIndex].bodyRange)
                        .trimmingCharacters(in: .whitespaces)
                    if closesFence(candidate, opening: fence.marker) { break }
                }
                let fullRange = NSRange(
                    location: line.fullRange.location,
                    length: NSMaxRange(lines[endIndex].fullRange) - line.fullRange.location
                )
                let contentStart = NSMaxRange(line.fullRange)
                let closes =
                    endIndex > index
                    && closesFence(
                        text.substring(with: lines[endIndex].bodyRange)
                            .trimmingCharacters(in: .whitespaces),
                        opening: fence.marker
                    )
                let contentEnd = closes ? lines[endIndex].fullRange.location : NSMaxRange(fullRange)
                var syntax = [line.bodyRange]
                if closes { syntax.append(lines[endIndex].bodyRange) }
                result.append(
                    MarkdownBlock(
                        id: MarkdownBlockID(),
                        kind: .fencedCode(language: language(forFenceLabel: fence.language)),
                        depth: indentationDepth(in: body),
                        sourceRange: fullRange,
                        contentRange: NSRange(
                            location: contentStart,
                            length: max(contentEnd - contentStart, 0)
                        ),
                        syntaxRanges: syntax,
                        inlineSpans: [],
                        source: text.substring(with: fullRange)
                    )
                )
                index = endIndex + 1
                continue
            }

            if trimmed == "$$" {
                var endIndex = index
                while endIndex + 1 < lines.count {
                    endIndex += 1
                    let candidate = text.substring(with: lines[endIndex].bodyRange)
                        .trimmingCharacters(in: .whitespaces)
                    if candidate == "$$" { break }
                }
                let fullRange = NSRange(
                    location: line.fullRange.location,
                    length: NSMaxRange(lines[endIndex].fullRange) - line.fullRange.location
                )
                let closes =
                    endIndex > index
                    && text.substring(with: lines[endIndex].bodyRange)
                        .trimmingCharacters(in: .whitespaces) == "$$"
                let contentStart = NSMaxRange(line.fullRange)
                let contentEnd = closes ? lines[endIndex].fullRange.location : NSMaxRange(fullRange)
                var syntax = [line.bodyRange]
                if closes { syntax.append(lines[endIndex].bodyRange) }
                result.append(
                    MarkdownBlock(
                        id: MarkdownBlockID(),
                        kind: .math,
                        depth: indentationDepth(in: body),
                        sourceRange: fullRange,
                        contentRange: NSRange(
                            location: contentStart,
                            length: max(contentEnd - contentStart, 0)
                        ),
                        syntaxRanges: syntax,
                        inlineSpans: [],
                        source: text.substring(with: fullRange)
                    )
                )
                index = endIndex + 1
                continue
            }

            result.append(parseLine(line, body: body, fullSource: text))
            index += 1
        }
        markTableBlocks(in: &result, source: text)
        attachInlineSpans(in: &result, source: source)
        return result
    }

    private static func parseLine(
        _ line: SourceLine,
        body: String,
        fullSource: NSString
    ) -> MarkdownBlock {
        let local = body as NSString
        let indentLength = leadingIndentLength(in: local)
        let depth = indentationDepth(in: body)
        let remainderRange = NSRange(
            location: indentLength,
            length: max(local.length - indentLength, 0)
        )
        let remainder = local.substring(with: remainderRange)
        let marker = parseBlockMarker(in: remainder)
        let markerLength = marker?.length ?? 0
        let contentStart = line.bodyRange.location + indentLength + markerLength
        let contentRange = NSRange(
            location: contentStart,
            length: max(NSMaxRange(line.bodyRange) - contentStart, 0)
        )
        var syntaxRanges: [NSRange] = []
        if indentLength > 0 {
            syntaxRanges.append(NSRange(location: line.bodyRange.location, length: indentLength))
        }
        if markerLength > 0 {
            syntaxRanges.append(
                NSRange(
                    location: line.bodyRange.location + indentLength,
                    length: markerLength
                )
            )
        }
        let kind = marker?.kind ?? fallbackKind(for: remainder)
        return MarkdownBlock(
            id: MarkdownBlockID(),
            kind: kind,
            depth: depth,
            sourceRange: line.fullRange,
            contentRange: contentRange,
            syntaxRanges: syntaxRanges,
            inlineSpans: [],
            source: fullSource.substring(with: line.fullRange)
        )
    }

    private static func parseBlockMarker(in value: String) -> (
        kind: MarkdownBlockKind, length: Int
    )? {
        let text = value as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        guard let first = value.first else { return nil }

        if first == "#",
            let match = firstMatch(#"^(#{1,6})[ \t]+"#, in: value, range: fullRange)
        {
            return (.heading(level: match.range(at: 1).length), match.range.length)
        }
        if "-+*".contains(first),
            let match = firstMatch(
                #"^[-+*][ \t]+\[([ xX])\][ \t]+"#,
                in: value,
                range: fullRange
            )
        {
            let state = text.substring(with: match.range(at: 1)).lowercased() == "x"
            return (.taskItem(isCompleted: state), match.range.length)
        }
        if "-+*".contains(first),
            let match = firstMatch(#"^[-+*][ \t]+"#, in: value, range: fullRange)
        {
            return (.bulletedListItem, match.range.length)
        }
        if first.isNumber,
            let match = firstMatch(#"^([0-9]+)[.)][ \t]+"#, in: value, range: fullRange)
        {
            let ordinal = Int(text.substring(with: match.range(at: 1))) ?? 1
            return (.numberedListItem(ordinal: ordinal), match.range.length)
        }
        if first == ">", let match = firstMatch(#"^>[ \t]?"#, in: value, range: fullRange) {
            return (.quote, match.range.length)
        }
        return nil
    }

    private static func fallbackKind(for value: String) -> MarkdownBlockKind {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        if let first = trimmed.first, "-_*".contains(first),
            firstMatch(#"^(?:-{3,}|_{3,}|\*{3,})[ \t]*$"#, in: value) != nil
        {
            return .divider
        }
        return .paragraph
    }

    private static func markTableBlocks(
        in blocks: inout [MarkdownBlock],
        source: NSString
    ) {
        guard blocks.count >= 2 else { return }
        for index in 1..<blocks.count {
            let separator = source.substring(with: blocks[index].contentRange)
            guard
                firstMatch(
                    #"^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$"#,
                    in: separator
                ) != nil,
                source.substring(with: blocks[index - 1].contentRange).contains("|")
            else { continue }

            var row = index - 1
            while row < blocks.count {
                let contents = source.substring(with: blocks[row].contentRange)
                guard contents.contains("|"), !contents.trimmingCharacters(in: .whitespaces).isEmpty
                else { break }
                blocks[row].kind = .table
                blocks[row].inlineSpans = []
                row += 1
            }
        }
    }

    /// Parses inline Markdown once with full-document context. This is needed
    /// for constructs whose meaning lives outside one physical line, such as
    /// reference-style links and emphasis that crosses a soft line break.
    private static func attachInlineSpans(
        in blocks: inout [MarkdownBlock],
        source: String
    ) {
        guard source.contains(where: { "*_~`[$<".contains($0) }) else { return }

        var collector = MarkdownInlineCollector(source: source)
        collector.visit(Document(parsing: source))
        var spans = collector.spans

        // Math is a Clip extension rather than CommonMark. Keep it out of code
        // and links, where dollar signs are literal content or destinations.
        let protectedRanges = spans.compactMap { span -> [NSRange]? in
            switch span.kind {
            case .code, .link:
                [span.contentRange] + span.syntaxRanges
            default:
                nil
            }
        }.flatMap { $0 }
        var mathSpans: [MarkdownInlineSpan] = []
        appendInlineMatches(
            #"(?<![\\$])\$([^\n$]+)\$(?!\$)"#,
            kind: { _ in .math },
            contentGroups: [1],
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length),
            offset: 0,
            into: &mathSpans
        )
        spans.append(
            contentsOf: mathSpans.filter { candidate in
                let candidateRanges = [candidate.contentRange] + candidate.syntaxRanges
                return !candidateRanges.contains { candidateRange in
                    protectedRanges.contains { rangesOverlap(candidateRange, $0) }
                }
            })
        spans.sort {
            if $0.contentRange.location == $1.contentRange.location {
                return $0.contentRange.length > $1.contentRange.length
            }
            return $0.contentRange.location < $1.contentRange.location
        }

        for index in blocks.indices {
            switch blocks[index].kind {
            case .fencedCode, .math, .divider, .empty, .table:
                blocks[index].inlineSpans = []
            default:
                blocks[index].inlineSpans = spans.compactMap {
                    clipped($0, to: blocks[index].contentRange)
                }
            }
        }
    }

    /// Most keystrokes need only the edited line. Reparse inline structure with
    /// document context only when an edit can affect a cross-line construct or
    /// a reference definition. This keeps very large notes responsive without
    /// letting reference links or multiline emphasis become stale.
    private static func requiresDocumentInlineRefresh(
        oldFragment: String,
        newFragment: String,
        lineSource: String,
        oldBlock: MarkdownBlock,
        oldSource: NSString
    ) -> Bool {
        let structuralInlineCharacters = "*_~`[$<"
        if oldFragment.contains(where: structuralInlineCharacters.contains)
            || newFragment.contains(where: structuralInlineCharacters.contains)
        {
            return true
        }
        if firstMatch(
            #"(?m)^[ \t]{0,3}\[[^\]\r\n]+\]:"#,
            in: lineSource
        ) != nil {
            return true
        }

        for span in oldBlock.inlineSpans {
            // A clipped run without both delimiters crosses a physical block.
            if span.syntaxRanges.count < 2 { return true }
            guard case .link = span.kind, let trailing = span.syntaxRanges.last,
                trailing.location >= 0, NSMaxRange(trailing) <= oldSource.length
            else { continue }
            let syntax = oldSource.substring(with: trailing)
            // Inline links and autolinks are self-contained. Reference and
            // shortcut links depend on definitions elsewhere in the document.
            if !syntax.hasPrefix("](") && syntax != ">" { return true }
        }
        return false
    }

    private static func clipped(
        _ span: MarkdownInlineSpan,
        to contentRange: NSRange
    ) -> MarkdownInlineSpan? {
        let content = NSIntersectionRange(span.contentRange, contentRange)
        guard content.length > 0 else { return nil }
        return MarkdownInlineSpan(
            kind: span.kind,
            contentRange: content,
            syntaxRanges: span.syntaxRanges.compactMap { syntaxRange in
                let intersection = NSIntersectionRange(syntaxRange, contentRange)
                return intersection.length > 0 ? intersection : nil
            }
        )
    }

    private struct MarkdownInlineCollector: MarkupWalker {
        var source: String
        var coordinates: SourceCoordinateMap
        var spans: [MarkdownInlineSpan] = []

        init(source: String) {
            self.source = source
            coordinates = SourceCoordinateMap(source: source)
        }

        mutating func visitStrong(_ strong: Strong) {
            appendDelimited(.strong, range: strong.range, leading: 2, trailing: 2)
            descendInto(strong)
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) {
            appendDelimited(.emphasis, range: emphasis.range, leading: 1, trailing: 1)
            descendInto(emphasis)
        }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
            appendDelimited(
                .strikethrough,
                range: strikethrough.range,
                leading: 2,
                trailing: 2
            )
            descendInto(strikethrough)
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            guard let fullRange = nsRange(for: inlineCode.range) else { return }
            let text = source as NSString
            var delimiterLength = 0
            while delimiterLength < fullRange.length,
                text.character(at: fullRange.location + delimiterLength) == 96
            {
                delimiterLength += 1
            }
            guard delimiterLength > 0, fullRange.length >= delimiterLength * 2 else {
                return
            }
            appendDelimited(
                .code,
                fullRange: fullRange,
                leading: delimiterLength,
                trailing: delimiterLength
            )
        }

        mutating func visitLink(_ link: Link) {
            guard let fullRange = nsRange(for: link.range),
                let parts = linkParts(in: fullRange)
            else {
                descendInto(link)
                return
            }
            spans.append(
                MarkdownInlineSpan(
                    kind: .link(destination: link.destination ?? parts.destination),
                    contentRange: parts.contentRange,
                    syntaxRanges: parts.syntaxRanges
                )
            )
            descendInto(link)
        }

        private mutating func appendDelimited(
            _ kind: MarkdownInlineKind,
            range: SourceRange?,
            leading: Int,
            trailing: Int
        ) {
            guard let fullRange = nsRange(for: range) else { return }
            appendDelimited(kind, fullRange: fullRange, leading: leading, trailing: trailing)
        }

        private mutating func appendDelimited(
            _ kind: MarkdownInlineKind,
            fullRange: NSRange,
            leading: Int,
            trailing: Int
        ) {
            guard fullRange.length >= leading + trailing else { return }
            let contentRange = NSRange(
                location: fullRange.location + leading,
                length: fullRange.length - leading - trailing
            )
            spans.append(
                MarkdownInlineSpan(
                    kind: kind,
                    contentRange: contentRange,
                    syntaxRanges: [
                        NSRange(location: fullRange.location, length: leading),
                        NSRange(
                            location: NSMaxRange(fullRange) - trailing,
                            length: trailing
                        ),
                    ]
                )
            )
        }

        private func nsRange(for sourceRange: SourceRange?) -> NSRange? {
            coordinates.nsRange(for: sourceRange)
        }

        private func linkParts(in fullRange: NSRange) -> (
            contentRange: NSRange,
            syntaxRanges: [NSRange],
            destination: String
        )? {
            let text = source as NSString
            guard fullRange.length >= 3,
                fullRange.location >= 0,
                NSMaxRange(fullRange) <= text.length
            else { return nil }

            if text.character(at: fullRange.location) == 60,
                text.character(at: NSMaxRange(fullRange) - 1) == 62
            {
                return (
                    NSRange(
                        location: fullRange.location + 1,
                        length: fullRange.length - 2
                    ),
                    [
                        NSRange(location: fullRange.location, length: 1),
                        NSRange(location: NSMaxRange(fullRange) - 1, length: 1),
                    ],
                    text.substring(
                        with: NSRange(
                            location: fullRange.location + 1,
                            length: fullRange.length - 2
                        )
                    )
                )
            }

            guard text.character(at: fullRange.location) == 91 else { return nil }

            let end = NSMaxRange(fullRange)
            var location = fullRange.location + 1
            var bracketDepth = 1
            var closingBracket: Int?
            while location < end {
                let character = text.character(at: location)
                if character == 92 {
                    location += 2
                    continue
                }
                if character == 91 { bracketDepth += 1 }
                if character == 93 {
                    bracketDepth -= 1
                    if bracketDepth == 0 {
                        closingBracket = location
                        break
                    }
                }
                location += 1
            }
            guard let closingBracket else { return nil }

            let contentRange = NSRange(
                location: fullRange.location + 1,
                length: closingBracket - fullRange.location - 1
            )
            let trailingRange = NSRange(
                location: closingBracket,
                length: end - closingBracket
            )
            var destination = ""
            if closingBracket + 1 < end,
                text.character(at: closingBracket + 1) == 40,
                trailingRange.length >= 3
            {
                let rawDestination = NSRange(
                    location: closingBracket + 2,
                    length: max(end - closingBracket - 3, 0)
                )
                destination = text.substring(with: rawDestination)
            }
            return (
                contentRange,
                [
                    NSRange(location: fullRange.location, length: 1),
                    trailingRange,
                ],
                destination
            )
        }
    }

    /// Converts swift-markdown's 1-based UTF-8 line/column locations to the
    /// UTF-16 offsets used by AppKit and Foundation ranges.
    private struct SourceCoordinateMap {
        private struct LineStart {
            var utf8Offset: Int
            var utf16Offset: Int
        }

        private var source: String
        private var lines: [LineStart] = [LineStart(utf8Offset: 0, utf16Offset: 0)]

        init(source: String) {
            self.source = source
            var utf8Offset = 0
            var utf16Offset = 0
            var pendingCarriageReturn = false

            for scalar in source.unicodeScalars {
                if pendingCarriageReturn, scalar.value != 10 {
                    lines.append(
                        LineStart(utf8Offset: utf8Offset, utf16Offset: utf16Offset)
                    )
                    pendingCarriageReturn = false
                }

                utf8Offset += scalar.utf8.count
                utf16Offset += scalar.utf16.count
                if scalar.value == 10 {
                    lines.append(
                        LineStart(utf8Offset: utf8Offset, utf16Offset: utf16Offset)
                    )
                    pendingCarriageReturn = false
                } else if scalar.value == 13 {
                    pendingCarriageReturn = true
                }
            }
            if pendingCarriageReturn {
                lines.append(LineStart(utf8Offset: utf8Offset, utf16Offset: utf16Offset))
            }
        }

        func nsRange(for sourceRange: SourceRange?) -> NSRange? {
            guard let sourceRange,
                let lower = utf16Location(
                    line: sourceRange.lowerBound.line,
                    utf8Column: sourceRange.lowerBound.column
                ),
                let upper = utf16Location(
                    line: sourceRange.upperBound.line,
                    utf8Column: sourceRange.upperBound.column
                ),
                upper >= lower
            else { return nil }
            return NSRange(location: lower, length: upper - lower)
        }

        private func utf16Location(line: Int, utf8Column: Int) -> Int? {
            guard line > 0, line <= lines.count else { return nil }
            let lineStart = lines[line - 1]
            let byteOffset = lineStart.utf8Offset + max(utf8Column - 1, 0)
            guard byteOffset >= lineStart.utf8Offset, byteOffset <= source.utf8.count else {
                return nil
            }
            let utf8Index = source.utf8.index(source.utf8.startIndex, offsetBy: byteOffset)
            guard let index = String.Index(utf8Index, within: source),
                let startUTF8Index = source.utf8.index(
                    source.utf8.startIndex,
                    offsetBy: lineStart.utf8Offset,
                    limitedBy: source.utf8.endIndex
                ),
                let start = String.Index(startUTF8Index, within: source)
            else { return nil }
            return lineStart.utf16Offset + source[start..<index].utf16.count
        }
    }

    private static func appendInlineMatches(
        _ pattern: String,
        kind: (NSTextCheckingResult) -> MarkdownInlineKind,
        contentGroups: [Int],
        in value: String,
        range: NSRange,
        offset: Int,
        into spans: inout [MarkdownInlineSpan]
    ) {
        guard let expression = regexCache.expression(for: pattern) else { return }
        for match in expression.matches(in: value, range: range) {
            guard
                let content = contentGroups.lazy.map({ match.range(at: $0) }).first(where: {
                    $0.location != NSNotFound
                })
            else { continue }
            spans.append(
                MarkdownInlineSpan(
                    kind: kind(match),
                    contentRange: shifted(content, by: offset),
                    syntaxRanges: delimiterRanges(
                        around: content,
                        in: match.range,
                        preserving: [],
                        offset: offset
                    )
                )
            )
        }
    }

    private static func reconcileIDs(
        in blocks: inout [MarkdownBlock],
        with previous: [MarkdownBlock],
        edit: SyntaxEdit?,
        previousSourceLength: Int?,
        sourceLength: Int
    ) {
        guard !previous.isEmpty else { return }
        var unused = Set(previous.indices)
        var matchedNew: Set<Int> = []

        // An explicit edit tells us which duplicate blocks are truly before
        // and after the change. Pin those unaffected regions before the
        // content-based queues run, then retain the edited block's identity at
        // the edit anchor when it has not simply shifted into the suffix.
        if let edit, let previousSourceLength,
            edit.previousRange.location >= 0, edit.previousRange.length >= 0,
            edit.currentRange.location >= 0, edit.currentRange.length >= 0,
            NSMaxRange(edit.previousRange) <= previousSourceLength,
            NSMaxRange(edit.currentRange) <= sourceLength
        {
            let oldPrefix = previous.indices.filter {
                previous[$0].sourceRange.length > 0
                    && NSMaxRange(previous[$0].sourceRange) <= edit.previousRange.location
            }
            let newPrefix = blocks.indices.filter {
                blocks[$0].sourceRange.length > 0
                    && NSMaxRange(blocks[$0].sourceRange) <= edit.currentRange.location
            }
            for (oldIndex, newIndex) in zip(oldPrefix, newPrefix) {
                let oldSignature = ExactBlockSignature(
                    kind: previous[oldIndex].kind,
                    source: previous[oldIndex].source
                )
                let newSignature = ExactBlockSignature(
                    kind: blocks[newIndex].kind,
                    source: blocks[newIndex].source
                )
                guard oldSignature == newSignature else { continue }
                blocks[newIndex].id = previous[oldIndex].id
                unused.remove(oldIndex)
                matchedNew.insert(newIndex)
            }

            let oldSuffix = previous.indices.filter {
                previous[$0].sourceRange.length > 0
                    && previous[$0].sourceRange.location >= NSMaxRange(edit.previousRange)
            }.reversed()
            let newSuffix = blocks.indices.filter {
                blocks[$0].sourceRange.length > 0
                    && blocks[$0].sourceRange.location >= NSMaxRange(edit.currentRange)
            }.reversed()
            for (oldIndex, newIndex) in zip(oldSuffix, newSuffix) {
                let oldSignature = ExactBlockSignature(
                    kind: previous[oldIndex].kind,
                    source: previous[oldIndex].source
                )
                let newSignature = ExactBlockSignature(
                    kind: blocks[newIndex].kind,
                    source: blocks[newIndex].source
                )
                guard oldSignature == newSignature else { continue }
                blocks[newIndex].id = previous[oldIndex].id
                unused.remove(oldIndex)
                matchedNew.insert(newIndex)
            }

            let oldAnchor = blockIndex(
                containing: NSRange(location: edit.previousRange.location, length: 0),
                sourceLength: previousSourceLength,
                in: previous
            )
            let newAnchor = blockIndex(
                containing: NSRange(location: edit.currentRange.location, length: 0),
                sourceLength: sourceLength,
                in: blocks
            )
            if let oldAnchor, let newAnchor,
                unused.contains(oldAnchor), !matchedNew.contains(newAnchor)
            {
                blocks[newAnchor].id = previous[oldAnchor].id
                unused.remove(oldAnchor)
                matchedNew.insert(newAnchor)
            }
        }

        var exactIndices: [ExactBlockSignature: [Int]] = [:]
        for index in previous.indices {
            exactIndices[
                ExactBlockSignature(kind: previous[index].kind, source: previous[index].source),
                default: []
            ].append(index)
        }
        var exactCursors: [ExactBlockSignature: Int] = [:]

        // First keep exact blocks using monotonic queues. This is linear even
        // for long notes with thousands of repeated or empty paragraphs.
        for index in blocks.indices where !matchedNew.contains(index) {
            let signature = ExactBlockSignature(
                kind: blocks[index].kind,
                source: blocks[index].source
            )
            guard let candidates = exactIndices[signature] else { continue }
            var cursor = exactCursors[signature, default: 0]
            while cursor < candidates.count, !unused.contains(candidates[cursor]) {
                cursor += 1
            }
            exactCursors[signature] = cursor + 1
            guard cursor < candidates.count else { continue }
            let match = candidates[cursor]
            blocks[index].id = previous[match].id
            unused.remove(match)
            matchedNew.insert(index)
        }

        // Then preserve the identity of a locally edited block at the same
        // structural position. This is what keeps a caret/selection anchored
        // while the user changes the block's contents or type.
        var familyIndices: [StructuralFamilyKey: [Int]] = [:]
        for oldIndex in previous.indices where unused.contains(oldIndex) {
            familyIndices[
                StructuralFamilyKey(
                    depth: previous[oldIndex].depth,
                    family: structuralFamily(previous[oldIndex].kind)
                ),
                default: []
            ].append(oldIndex)
        }
        var familyCursors: [StructuralFamilyKey: Int] = [:]
        for index in blocks.indices where !matchedNew.contains(index) {
            let key = StructuralFamilyKey(
                depth: blocks[index].depth,
                family: structuralFamily(blocks[index].kind)
            )
            guard let candidates = familyIndices[key] else { continue }
            var cursor = familyCursors[key, default: 0]
            while cursor < candidates.count, !unused.contains(candidates[cursor]) {
                cursor += 1
            }
            familyCursors[key] = cursor + 1
            guard cursor < candidates.count else { continue }
            let match = candidates[cursor]
            blocks[index].id = previous[match].id
            unused.remove(match)
        }
    }

    private static func connectHierarchy(in blocks: inout [MarkdownBlock]) {
        for index in blocks.indices {
            blocks[index].parentID = nil
            blocks[index].childIDs = []
        }
        var stack: [(depth: Int, id: MarkdownBlockID)] = []
        var indexByID: [MarkdownBlockID: Int] = [:]
        for index in blocks.indices {
            while let last = stack.last, last.depth >= blocks[index].depth {
                stack.removeLast()
            }
            blocks[index].parentID = stack.last?.id
            if let parentID = blocks[index].parentID, let parentIndex = indexByID[parentID] {
                blocks[parentIndex].childIDs.append(blocks[index].id)
            }
            indexByID[blocks[index].id] = index
            stack.append((blocks[index].depth, blocks[index].id))
        }
    }

    private struct ExactBlockSignature: Hashable {
        var kind: MarkdownBlockKind
        var source: String
    }

    private struct StructuralFamilyKey: Hashable {
        var depth: Int
        var family: Int
    }

    private static func structuralFamily(_ kind: MarkdownBlockKind) -> Int {
        switch kind {
        case .paragraph, .heading, .quote: 0
        case .bulletedListItem, .numberedListItem, .taskItem: 1
        case .fencedCode: 2
        case .math: 3
        case .divider: 4
        case .table: 5
        case .empty: 6
        case .raw: 7
        }
    }

    private static func validateNonOverlapping(
        _ replacements: [SourceReplacement]
    ) throws {
        let nonempty = replacements.filter { $0.range.length > 0 }.sorted {
            $0.range.location < $1.range.location
        }
        for pair in zip(nonempty, nonempty.dropFirst())
        where NSIntersectionRange(pair.0.range, pair.1.range).length > 0 {
            throw MarkdownDocumentError.invalidRange(pair.1.range)
        }

        for insertion in replacements where insertion.range.length == 0 {
            let location = insertion.range.location
            if let containing = nonempty.first(where: {
                location > $0.range.location && location < NSMaxRange($0.range)
            }) {
                throw MarkdownDocumentError.invalidRange(containing.range)
            }
        }
    }

    private static func replacementSort(
        _ lhs: SourceReplacement,
        _ rhs: SourceReplacement
    ) -> Bool {
        if lhs.range.location == rhs.range.location {
            // Deletions occur before insertions at the same source location.
            if (lhs.range.length == 0) != (rhs.range.length == 0) {
                return lhs.range.length > 0
            }
            // Applying same-point inserts in reverse operation order preserves
            // the transaction's declared order in the resulting source.
            return lhs.order > rhs.order
        }
        return lhs.range.location > rhs.range.location
    }

    private static func normalizedBlockSource(
        _ value: String,
        lineEnding: String
    ) -> String {
        guard !value.isEmpty, !value.hasSuffix("\n"), !value.hasSuffix("\r") else {
            return value
        }
        return value + lineEnding
    }

    private static func preferredLineEnding(in source: String) -> String {
        if source.contains("\r\n") { return "\r\n" }
        if source.contains("\r") { return "\r" }
        return "\n"
    }

    private static func insertionSource(
        _ value: String,
        at location: Int,
        in source: String,
        lineEnding: String
    ) -> String {
        guard !value.isEmpty, location > 0 else { return value }
        let text = source as NSString
        guard location <= text.length else { return value }
        let previous = text.character(at: location - 1)
        if previous == 10 || previous == 13 { return value }
        return lineEnding + value
    }

    private static func subtreeSourceRange(
        at index: Int,
        in blocks: [MarkdownBlock]
    ) -> NSRange {
        let depth = blocks[index].depth
        var endIndex = index
        while endIndex + 1 < blocks.count, blocks[endIndex + 1].depth > depth {
            endIndex += 1
        }
        return NSRange(
            location: blocks[index].sourceRange.location,
            length: NSMaxRange(blocks[endIndex].sourceRange)
                - blocks[index].sourceRange.location
        )
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    private static func plannedSubtreeRange(
        at index: Int,
        in plan: [PlannedBlockIdentity]
    ) -> Range<Int> {
        let depth = plan[index].depth
        var end = index + 1
        while end < plan.count, plan[end].depth > depth {
            end += 1
        }
        return index..<end
    }

    private static func plannedIdentities(from source: String) -> [PlannedBlockIdentity] {
        guard !source.isEmpty else { return [] }
        var blocks = parse(source)
        if blocks.last?.sourceRange.length == 0,
            source.hasSuffix("\n") || source.hasSuffix("\r")
        {
            blocks.removeLast()
        }
        return blocks.map {
            PlannedBlockIdentity(id: MarkdownBlockID(), depth: $0.depth)
        }
    }

    private static func replaceIdentity(
        _ id: MarkdownBlockID,
        with source: String,
        in plan: inout [PlannedBlockIdentity]?
    ) {
        guard var current = plan,
            let index = current.firstIndex(where: { $0.id == id })
        else { return }
        var replacement = plannedIdentities(from: source)
        if !replacement.isEmpty { replacement[0].id = id }
        current.replaceSubrange(index...index, with: replacement)
        plan = current
    }

    private static func insertIdentities(
        from source: String,
        after id: MarkdownBlockID?,
        in plan: inout [PlannedBlockIdentity]?
    ) {
        guard var current = plan else { return }
        let insertionIndex: Int
        if let id, let index = current.firstIndex(where: { $0.id == id }) {
            insertionIndex = plannedSubtreeRange(at: index, in: current).upperBound
        } else if id == nil {
            insertionIndex = 0
        } else {
            plan = nil
            return
        }
        current.insert(contentsOf: plannedIdentities(from: source), at: insertionIndex)
        plan = current
    }

    private static func deleteIdentity(
        _ id: MarkdownBlockID,
        in plan: inout [PlannedBlockIdentity]?
    ) {
        guard var current = plan,
            let index = current.firstIndex(where: { $0.id == id })
        else { return }
        current.remove(at: index)
        plan = current
    }

    private static func moveIdentity(
        _ id: MarkdownBlockID,
        after targetID: MarkdownBlockID?,
        in plan: inout [PlannedBlockIdentity]?
    ) {
        guard var current = plan,
            let sourceIndex = current.firstIndex(where: { $0.id == id })
        else { return }
        let sourceRange = plannedSubtreeRange(at: sourceIndex, in: current)
        let moving = Array(current[sourceRange])
        if let targetID,
            moving.contains(where: { $0.id == targetID })
        {
            return
        }
        current.removeSubrange(sourceRange)
        let insertionIndex: Int
        if let targetID,
            let targetIndex = current.firstIndex(where: { $0.id == targetID })
        {
            insertionIndex = plannedSubtreeRange(at: targetIndex, in: current).upperBound
        } else if targetID == nil {
            insertionIndex = 0
        } else {
            plan = nil
            return
        }
        current.insert(contentsOf: moving, at: insertionIndex)
        plan = current
    }

    private struct SourceLine {
        var fullRange: NSRange
        var bodyRange: NSRange
    }

    private static func sourceLines(in source: NSString) -> [SourceLine] {
        guard source.length > 0 else { return [] }
        var lines: [SourceLine] = []
        var location = 0
        while location < source.length {
            let fullRange = source.lineRange(for: NSRange(location: location, length: 0))
            var bodyLength = fullRange.length
            if bodyLength > 0, source.character(at: NSMaxRange(fullRange) - 1) == 10 {
                bodyLength -= 1
                if bodyLength > 0, source.character(at: fullRange.location + bodyLength - 1) == 13 {
                    bodyLength -= 1
                }
            } else if bodyLength > 0, source.character(at: NSMaxRange(fullRange) - 1) == 13 {
                bodyLength -= 1
            }
            lines.append(
                SourceLine(
                    fullRange: fullRange,
                    bodyRange: NSRange(location: fullRange.location, length: bodyLength)
                )
            )
            location = NSMaxRange(fullRange)
        }
        let lastCharacter = source.character(at: source.length - 1)
        if lastCharacter == 10 || lastCharacter == 13 {
            let emptyRange = NSRange(location: source.length, length: 0)
            lines.append(SourceLine(fullRange: emptyRange, bodyRange: emptyRange))
        }
        return lines
    }

    private static func leadingIndentLength(in value: NSString) -> Int {
        var location = 0
        while location < value.length {
            let character = value.character(at: location)
            guard character == 9 || character == 32 else { break }
            location += 1
        }
        return location
    }

    private static func indentationDepth(in value: String) -> Int {
        var columns = 0
        for character in value {
            if character == "\t" {
                columns += 4
            } else if character == " " {
                columns += 1
            } else {
                break
            }
        }
        return columns / 2
    }

    private static func openingFence(in value: String) -> (marker: String, language: String)? {
        guard value.first == "`" || value.first == "~" else { return nil }
        guard let match = firstMatch(#"^(`{3,}|~{3,})[ \t]*([^ \t]*)"#, in: value) else {
            return nil
        }
        let text = value as NSString
        return (
            text.substring(with: match.range(at: 1)),
            match.range(at: 2).location == NSNotFound
                ? "" : text.substring(with: match.range(at: 2))
        )
    }

    private static func closesFence(_ value: String, opening: String) -> Bool {
        guard let first = opening.first else { return false }
        let marker = String(value.prefix { $0 == first })
        let rest = value.dropFirst(marker.count)
        return marker.count >= opening.count
            && rest.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func language(forFenceLabel label: String) -> LanguageID {
        let normalized = label.lowercased()
        switch normalized {
        case "", "text", "txt": return .plainText
        case "sh", "shell", "zsh", "bash": return .bash
        case "js", "jsx", "javascript": return .javascript
        case "ts", "tsx", "typescript": return .typescript
        case "py", "python": return .python
        case "c++", "cc", "cpp": return .cpp
        case "yml", "yaml": return .yaml
        case "htm", "html": return .html
        default:
            let candidate = LanguageID(rawValue: normalized)
            return candidate.hasTreeSitterGrammar ? candidate : .plainText
        }
    }

    private static func firstMatch(
        _ pattern: String,
        in value: String,
        range: NSRange? = nil
    ) -> NSTextCheckingResult? {
        guard let expression = regexCache.expression(for: pattern) else { return nil }
        return expression.firstMatch(
            in: value,
            range: range ?? NSRange(location: 0, length: (value as NSString).length)
        )
    }

    private static func delimiterRanges(
        around content: NSRange,
        in fullRange: NSRange,
        preserving: [NSRange],
        offset: Int
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        let leading = NSRange(
            location: fullRange.location,
            length: max(content.location - fullRange.location, 0)
        )
        let trailing = NSRange(
            location: NSMaxRange(content),
            length: max(NSMaxRange(fullRange) - NSMaxRange(content), 0)
        )
        for range in [leading, trailing] where range.length > 0 {
            ranges.append(shifted(range, by: offset))
        }
        return ranges + preserving.map { shifted($0, by: offset) }
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func shifted(_ block: MarkdownBlock, by offset: Int) -> MarkdownBlock {
        guard offset != 0 else { return block }
        var result = block
        result.sourceRange = shifted(block.sourceRange, by: offset)
        result.contentRange = shifted(block.contentRange, by: offset)
        result.syntaxRanges = block.syntaxRanges.map { shifted($0, by: offset) }
        result.inlineSpans = block.inlineSpans.map { span in
            MarkdownInlineSpan(
                kind: span.kind,
                contentRange: shifted(span.contentRange, by: offset),
                syntaxRanges: span.syntaxRanges.map { shifted($0, by: offset) }
            )
        }
        return result
    }

    private static let regexCache = MarkdownRegularExpressionCache()
}

private final class MarkdownRegularExpressionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var expressions: [String: NSRegularExpression] = [:]

    func expression(for pattern: String) -> NSRegularExpression? {
        lock.withLock {
            if let expression = expressions[pattern] { return expression }
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            expressions[pattern] = expression
            return expression
        }
    }
}
