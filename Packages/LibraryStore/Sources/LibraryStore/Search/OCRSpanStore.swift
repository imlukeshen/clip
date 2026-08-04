import CoreModel
import Foundation
import GRDB

extension LibraryStore {
    /// Atomically replaces one asset's OCR result after a complete successful pass.
    /// Existing rows stay searchable while a newer Vision revision is processing.
    public func replaceOCRSpans(_ spans: [OCRSpan], for assetID: AssetID) async throws {
        let encoder = JSONEncoder()
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM ocr_span WHERE asset_id = ?",
                    arguments: [assetID.rawValue]
                )
                for span in spans {
                    let box = try String(
                        decoding: encoder.encode(span.boundingBox),
                        as: UTF8.self
                    )
                    try db.execute(
                        sql: """
                            INSERT INTO ocr_span (
                              asset_id, start_value, start_scale, end_value, end_scale,
                              text, bbox, confidence, revision, script
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            assetID.rawValue,
                            span.start?.value,
                            span.start?.timescale,
                            span.end?.value,
                            span.end?.timescale,
                            span.text,
                            box,
                            span.confidence,
                            span.revision,
                            span.script.rawValue,
                        ]
                    )
                }
            }
        } catch {
            throw LibraryError.databaseOperationFailed("replace OCR spans")
        }
    }

    /// Reads OCR regions for an asset, optionally constrained to a video moment.
    public func ocrSpans(
        for assetID: AssetID,
        at time: RationalTime? = nil,
        tolerance: RationalTime = RationalTime(seconds: 1)
    ) async throws -> [OCRSpan] {
        do {
            return try await database.read { db in
                let rows: [Row]
                if let time {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT * FROM ocr_span
                            WHERE asset_id = ?
                              AND (
                                start_value IS NULL OR
                                (
                                  start_value <= ? + ? AND
                                  COALESCE(end_value, start_value) >= ? - ?
                                )
                              )
                            ORDER BY start_value ASC, id ASC
                            """,
                        arguments: [
                            assetID.rawValue,
                            time.value,
                            tolerance.value,
                            time.value,
                            tolerance.value,
                        ]
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT * FROM ocr_span
                            WHERE asset_id = ?
                            ORDER BY start_value ASC, id ASC
                            """,
                        arguments: [assetID.rawValue]
                    )
                }
                return rows.compactMap(Self.decodeOCRSpan)
            }
        } catch {
            throw LibraryError.databaseOperationFailed("read OCR spans")
        }
    }

    /// Requeues OCR rows made by an older Vision request revision without deleting
    /// their still-useful text before replacement succeeds.
    public func requeueStaleOCRJobs(currentRevision: Int) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                        UPDATE index_job
                        SET state = 'pending', attempts = 0, error = NULL, updated_at = ?
                        WHERE stage = 'ocr'
                          AND asset_id IN (
                            SELECT DISTINCT asset_id FROM ocr_span WHERE revision != ?
                          )
                        """,
                    arguments: [Date().timeIntervalSince1970, currentRevision]
                )
            }
        } catch {
            throw LibraryError.databaseOperationFailed("requeue stale OCR")
        }
    }

    private nonisolated static func decodeOCRSpan(_ row: Row) -> OCRSpan? {
        guard
            let assetRaw: String = row["asset_id"],
            let text: String = row["text"],
            let boxJSON: String = row["bbox"],
            let boxData = boxJSON.data(using: .utf8),
            let box = try? JSONDecoder().decode(NormalizedRect.self, from: boxData),
            let script = OCRScript(rawValue: row["script"] as String)
        else { return nil }
        let startValue: Int64? = row["start_value"]
        let startScale: Int32? = row["start_scale"]
        let endValue: Int64? = row["end_value"]
        let endScale: Int32? = row["end_scale"]
        return OCRSpan(
            id: row["id"],
            assetID: AssetID(rawValue: assetRaw),
            start: startValue.map { RationalTime(value: $0, timescale: startScale ?? 90_000) },
            end: endValue.map { RationalTime(value: $0, timescale: endScale ?? 90_000) },
            text: text,
            boundingBox: box,
            confidence: row["confidence"],
            revision: row["revision"],
            script: script
        )
    }
}
