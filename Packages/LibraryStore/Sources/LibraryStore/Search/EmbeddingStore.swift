import CoreModel
import Foundation
import GRDB

extension LibraryStore {
    /// Replaces one asset only after every new chunk has been embedded successfully.
    /// Old-model rows remain usable until this transaction commits.
    public func replaceEmbeddings(
        _ records: [EmbeddingRecord],
        for assetID: AssetID,
        removingOtherModels: Bool = true
    ) async throws {
        guard
            records.allSatisfy({
                $0.assetID == assetID && !$0.vector.isEmpty && $0.vector.allSatisfy(\.isFinite)
            })
        else {
            throw LibraryError.databaseOperationFailed("validate embeddings")
        }
        do {
            try await database.write { db in
                let models = Set(records.map(\.model)).sorted()
                if !models.isEmpty {
                    let placeholders = Array(repeating: "?", count: models.count).joined(
                        separator: ",")
                    try db.execute(
                        sql:
                            "DELETE FROM embedding WHERE asset_id = ? AND model IN (\(placeholders))",
                        arguments: StatementArguments([assetID.rawValue] + models)
                    )
                }
                for record in records {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO embedding (
                              asset_id, chunk_index, kind,
                              start_value, start_scale, end_value, end_scale,
                              text, vector, dims, model
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            assetID.rawValue,
                            record.chunkIndex,
                            record.kind.rawValue,
                            record.start?.value,
                            record.start?.timescale,
                            record.end?.value,
                            record.end?.timescale,
                            record.text,
                            Self.encodeVector(record.vector),
                            record.dimensions,
                            record.model,
                        ]
                    )
                }
                if models.isEmpty, removingOtherModels {
                    try db.execute(
                        sql: "DELETE FROM embedding WHERE asset_id = ?",
                        arguments: [assetID.rawValue]
                    )
                } else if !models.isEmpty, removingOtherModels {
                    let placeholders = Array(repeating: "?", count: models.count).joined(
                        separator: ",")
                    try db.execute(
                        sql:
                            "DELETE FROM embedding WHERE asset_id = ? AND model NOT IN (\(placeholders))",
                        arguments: StatementArguments([assetID.rawValue] + models)
                    )
                }
                try Self.bumpEmbeddingGeneration(db)
            }
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.databaseOperationFailed("replace embeddings")
        }
    }

    public func embeddingModels() async throws -> Set<String> {
        do {
            return try await database.read { db in
                Set(try String.fetchAll(db, sql: "SELECT DISTINCT model FROM embedding"))
            }
        } catch {
            throw LibraryError.databaseOperationFailed("read embedding models")
        }
    }

    public func embeddingGeneration() async throws -> Int64 {
        do {
            return try await database.read { db in
                let value = try String.fetchOne(
                    db,
                    sql: "SELECT value FROM meta WHERE key = 'embeddingGeneration'"
                )
                return Int64(value ?? "0") ?? 0
            }
        } catch {
            throw LibraryError.databaseOperationFailed("read embedding generation")
        }
    }

    public func embeddingCount(model: String) async throws -> Int {
        do {
            return try await database.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM embedding WHERE model = ?",
                    arguments: [model]
                ) ?? 0
            }
        } catch {
            throw LibraryError.databaseOperationFailed("count embeddings")
        }
    }

    public func embeddings(
        model: String,
        limit: Int,
        offset: Int = 0
    ) async throws -> [EmbeddingRecord] {
        guard limit > 0, offset >= 0 else { return [] }
        do {
            return try await database.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT asset_id, chunk_index, kind,
                               start_value, start_scale, end_value, end_scale,
                               text, vector, dims, model
                        FROM embedding
                        WHERE model = ?
                        ORDER BY asset_id, chunk_index, kind
                        LIMIT ? OFFSET ?
                        """,
                    arguments: [model, limit, offset]
                ).compactMap(Self.decodeEmbedding)
            }
        } catch {
            throw LibraryError.databaseOperationFailed("read embeddings")
        }
    }

    private nonisolated static func encodeVector(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private nonisolated static func decodeEmbedding(_ row: Row) -> EmbeddingRecord? {
        guard let kind = SearchHitSource(rawValue: row["kind"] as String) else { return nil }
        let data: Data = row["vector"]
        let dimensions: Int = row["dims"]
        guard data.count == dimensions * MemoryLayout<UInt32>.size else { return nil }
        var vector: [Float] = []
        vector.reserveCapacity(dimensions)
        for offset in stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size) {
            let bits = data[offset..<(offset + 4)].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }
            vector.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }
        let startValue: Int64? = row["start_value"]
        let startScale: Int32? = row["start_scale"]
        let endValue: Int64? = row["end_value"]
        let endScale: Int32? = row["end_scale"]
        return EmbeddingRecord(
            assetID: AssetID(rawValue: row["asset_id"]),
            chunkIndex: row["chunk_index"],
            kind: kind,
            start: startValue.map { RationalTime(value: $0, timescale: startScale ?? 90_000) },
            end: endValue.map { RationalTime(value: $0, timescale: endScale ?? 90_000) },
            text: row["text"],
            vector: vector,
            model: row["model"]
        )
    }

    private nonisolated static func bumpEmbeddingGeneration(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO meta (key, value) VALUES ('embeddingGeneration', '1')
                ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
                """
        )
    }
}
