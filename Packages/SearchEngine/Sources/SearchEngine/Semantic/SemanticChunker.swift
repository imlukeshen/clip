import CoreModel
import Foundation
import LibraryStore

public struct SemanticChunk: Sendable, Equatable {
    public var index: Int
    public var kind: SearchHitSource
    public var start: RationalTime?
    public var end: RationalTime?
    public var text: String

    public init(
        index: Int,
        kind: SearchHitSource,
        start: RationalTime? = nil,
        end: RationalTime? = nil,
        text: String
    ) {
        self.index = index
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Builds timestamp-preserving, bounded chunks suitable for Apple's contextual model.
public enum SemanticChunker {
    public static let windowDuration = 30.0
    public static let maximumCharacters = 1_500

    public static func chunks(
        asset: AssetRecord,
        ocr: [OCRSpan],
        transcripts: [TranscriptSpan],
        text: [String] = []
    ) -> [SemanticChunk] {
        var drafts: [Draft] = [
            Draft(kind: .filename, bucket: -2, start: nil, end: nil, texts: [asset.displayName])
        ]
        drafts += text.enumerated().map { index, value in
            Draft(kind: .text, bucket: -1 + index, start: nil, end: nil, texts: [value])
        }
        drafts += groupedOCR(ocr)
        drafts += groupedTranscripts(transcripts)
        drafts.sort {
            if $0.bucket != $1.bucket { return $0.bucket < $1.bucket }
            return $0.kind.rawValue < $1.kind.rawValue
        }

        var result: [SemanticChunk] = []
        for draft in drafts {
            for text in split(draft.texts) where !text.isEmpty {
                result.append(
                    SemanticChunk(
                        index: result.count,
                        kind: draft.kind,
                        start: draft.start,
                        end: draft.end,
                        text: text
                    )
                )
            }
        }
        return result
    }

    private struct Draft {
        var kind: SearchHitSource
        var bucket: Int
        var start: RationalTime?
        var end: RationalTime?
        var texts: [String]
    }

    private static func groupedOCR(_ spans: [OCRSpan]) -> [Draft] {
        let groups = Dictionary(grouping: spans) { span in
            span.start.map { Int($0.seconds / windowDuration) } ?? -1
        }
        return groups.map { bucket, values in
            Draft(
                kind: .ocr,
                bucket: bucket,
                start: values.compactMap(\.start).min(),
                end: values.compactMap(\.end).max(),
                texts: values.sorted(by: readingOrder).map(\.text)
            )
        }
    }

    private static func groupedTranscripts(_ spans: [TranscriptSpan]) -> [Draft] {
        Dictionary(grouping: spans) { Int($0.start.seconds / windowDuration) }
            .map { bucket, values in
                Draft(
                    kind: .transcript,
                    bucket: bucket,
                    start: values.map(\.start).min(),
                    end: values.map(\.end).max(),
                    texts: values.sorted { $0.start < $1.start }.map(\.text)
                )
            }
    }

    private static func readingOrder(_ lhs: OCRSpan, _ rhs: OCRSpan) -> Bool {
        if lhs.start != rhs.start { return (lhs.start ?? .zero) < (rhs.start ?? .zero) }
        if abs(lhs.boundingBox.y - rhs.boundingBox.y) < 0.015 {
            return lhs.boundingBox.x < rhs.boundingBox.x
        }
        return lhs.boundingBox.y > rhs.boundingBox.y
    }

    private static func split(_ values: [String]) -> [String] {
        var chunks: [String] = []
        var current = ""
        for raw in values {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while !value.isEmpty {
                let remaining = maximumCharacters - current.count - (current.isEmpty ? 0 : 1)
                if remaining <= 0 {
                    chunks.append(current)
                    current = ""
                    continue
                }
                if value.count <= remaining {
                    if !current.isEmpty { current.append("\n") }
                    current.append(value)
                    value = ""
                } else {
                    let splitIndex = value.index(value.startIndex, offsetBy: remaining)
                    if !current.isEmpty { current.append("\n") }
                    current.append(contentsOf: value[..<splitIndex])
                    chunks.append(current)
                    current = ""
                    value = String(value[splitIndex...])
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
