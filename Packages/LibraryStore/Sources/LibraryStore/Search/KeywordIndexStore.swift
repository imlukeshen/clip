import CoreModel
import Foundation
import GRDB

extension LibraryStore {
    /// Atomically replaces the existing on-device transcript for one asset.
    public func replaceTranscriptSpans(
        _ spans: [TranscriptSpan],
        for assetID: AssetID
    ) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM transcript_span WHERE asset_id = ?",
                    arguments: [assetID.rawValue]
                )
                for span in spans {
                    try db.execute(
                        sql: """
                            INSERT INTO transcript_span (
                              asset_id, start_value, start_scale, end_value, end_scale,
                              text, script
                            ) VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            assetID.rawValue,
                            span.start.value,
                            span.start.timescale,
                            span.end.value,
                            span.end.timescale,
                            span.text,
                            span.script.rawValue,
                        ]
                    )
                }
            }
        } catch {
            throw LibraryError.databaseOperationFailed("replace transcript spans")
        }
    }

    public func transcriptSpans(for assetID: AssetID) async throws -> [TranscriptSpan] {
        do {
            return try await database.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, asset_id, start_value, start_scale,
                               end_value, end_scale, text, script
                        FROM transcript_span
                        WHERE asset_id = ?
                        ORDER BY start_value ASC, id ASC
                        """,
                    arguments: [assetID.rawValue]
                ).compactMap { row in
                    guard let script = OCRScript(rawValue: row["script"] as String) else {
                        return nil
                    }
                    return TranscriptSpan(
                        id: row["id"],
                        assetID: AssetID(rawValue: row["asset_id"]),
                        start: RationalTime(
                            value: row["start_value"],
                            timescale: row["start_scale"]
                        ),
                        end: RationalTime(
                            value: row["end_value"],
                            timescale: row["end_scale"]
                        ),
                        text: row["text"],
                        script: script
                    )
                }
            }
        } catch {
            throw LibraryError.databaseOperationFailed("read transcript spans")
        }
    }

    /// Runs escaped BM25 lookup over filenames, direct text, OCR, and transcripts.
    /// User input is always quoted here; callers cannot inject FTS5 operators.
    public func keywordMatches(
        terms: [String],
        phrases: [String],
        limit: Int
    ) async throws -> [IndexedTextMatch] {
        guard limit > 0 else { return [] }
        let components = (terms + phrases).filter { !$0.isEmpty }.map(Self.ftsQuote)
        guard !components.isEmpty else { return [] }
        let pattern = components.joined(separator: " ")
        let queryText = (terms + phrases).joined(separator: " ")
        let script = dominantScript(in: queryText)
        do {
            return try await database.read { db in
                var matches = try Self.filenameMatches(db, pattern: pattern, limit: limit)
                matches += try Self.spanMatches(
                    db,
                    table: "text_span",
                    ftsTable: "text_fts",
                    source: .text,
                    pattern: pattern,
                    literal: queryText,
                    script: script,
                    limit: limit
                )
                matches += try Self.spanMatches(
                    db,
                    table: "ocr_span",
                    ftsTable: "ocr_fts",
                    source: .ocr,
                    pattern: pattern,
                    literal: queryText,
                    script: script,
                    limit: limit
                )
                matches += try Self.spanMatches(
                    db,
                    table: "transcript_span",
                    ftsTable: "transcript_fts",
                    source: .transcript,
                    pattern: pattern,
                    literal: queryText,
                    script: script,
                    limit: limit
                )
                return matches
            }
        } catch {
            throw LibraryError.databaseOperationFailed("search keyword index")
        }
    }

    /// Whether every relevant durable job is terminal at query time.
    public func isTextIndexComplete(includeEmbeddings: Bool = false) async throws -> Bool {
        do {
            return try await database.read { db in
                let stages =
                    includeEmbeddings
                    ? "'text', 'ocr', 'transcript', 'embedding'"
                    : "'text', 'ocr', 'transcript'"
                let count =
                    try Int.fetchOne(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM index_job
                            WHERE stage IN (\(stages))
                              AND state IN ('pending', 'running')
                            """
                    ) ?? 0
                return count == 0
            }
        } catch {
            throw LibraryError.databaseOperationFailed("read text index completeness")
        }
    }

    private nonisolated static func filenameMatches(
        _ db: Database,
        pattern: String,
        limit: Int
    ) throws -> [IndexedTextMatch] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT asset_id, display_name, bm25(asset_fts, 0.0, 4.0, 2.0) AS rank
                FROM asset_fts
                WHERE asset_fts MATCH ?
                ORDER BY rank ASC
                LIMIT ?
                """,
            arguments: [pattern, limit]
        ).map { row in
            IndexedTextMatch(
                assetID: AssetID(rawValue: row["asset_id"]),
                source: .filename,
                text: row["display_name"],
                rank: row["rank"]
            )
        }
    }

    private nonisolated static func spanMatches(
        _ db: Database,
        table: String,
        ftsTable: String,
        source: SearchHitSource,
        pattern: String,
        literal: String,
        script: OCRScript,
        limit: Int
    ) throws -> [IndexedTextMatch] {
        if script == .cjk || script == .mixed {
            if literal.unicodeScalars.count < 3 {
                return try likeMatches(
                    db,
                    table: table,
                    source: source,
                    literal: literal,
                    limit: limit
                )
            }
            return try ftsSpanMatches(
                db,
                table: table,
                ftsTable: "\(ftsTable)_cjk",
                source: source,
                pattern: pattern,
                limit: limit
            )
        }
        return try ftsSpanMatches(
            db,
            table: table,
            ftsTable: ftsTable,
            source: source,
            pattern: pattern,
            limit: limit
        )
    }

    private nonisolated static func ftsSpanMatches(
        _ db: Database,
        table: String,
        ftsTable: String,
        source: SearchHitSource,
        pattern: String,
        limit: Int
    ) throws -> [IndexedTextMatch] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT span.asset_id, span.start_value, span.start_scale,
                  span.end_value, span.end_scale, span.text,
                  bm25(\(ftsTable), 4.0) AS rank
                FROM \(ftsTable)
                JOIN \(table) AS span ON span.id = \(ftsTable).rowid
                WHERE \(ftsTable) MATCH ?
                ORDER BY rank ASC
                LIMIT ?
                """,
            arguments: [pattern, limit]
        )
        return rows.map { decodeMatch($0, source: source, rankFallback: 0) }
    }

    private nonisolated static func likeMatches(
        _ db: Database,
        table: String,
        source: SearchHitSource,
        literal: String,
        limit: Int
    ) throws -> [IndexedTextMatch] {
        let escaped =
            literal
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT asset_id, start_value, start_scale, end_value, end_scale, text
                FROM \(table)
                WHERE text LIKE ? ESCAPE '\\'
                ORDER BY id ASC
                LIMIT ?
                """,
            arguments: ["%\(escaped)%", limit]
        )
        return rows.map { decodeMatch($0, source: source, rankFallback: -1) }
    }

    private nonisolated static func decodeMatch(
        _ row: Row,
        source: SearchHitSource,
        rankFallback: Double
    ) -> IndexedTextMatch {
        let startValue: Int64? = row["start_value"]
        let startScale: Int32? = row["start_scale"]
        let endValue: Int64? = row["end_value"]
        let endScale: Int32? = row["end_scale"]
        return IndexedTextMatch(
            assetID: AssetID(rawValue: row["asset_id"]),
            source: source,
            start: startValue.map { RationalTime(value: $0, timescale: startScale ?? 90_000) },
            end: endValue.map { RationalTime(value: $0, timescale: endScale ?? 90_000) },
            text: row["text"],
            rank: row.hasColumn("rank") ? row["rank"] : rankFallback
        )
    }

    private nonisolated static func ftsQuote(_ token: String) -> String {
        "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private nonisolated func dominantScript(in text: String) -> OCRScript {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF,
                0x0E00...0x0E7F:
                cjk += 1
            default:
                other += 1
            }
        }
        if cjk > 0, other > 0 { return .mixed }
        return cjk > 0 ? .cjk : .alphabetic
    }
}
