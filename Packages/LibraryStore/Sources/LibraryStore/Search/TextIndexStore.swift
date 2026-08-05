import CoreModel
import Foundation
import GRDB

extension LibraryStore {
    /// Atomically replaces the directly indexed chunks for one text asset.
    public func replaceTextChunks(
        _ chunks: [(text: String, script: OCRScript)],
        for assetID: AssetID
    ) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM text_span WHERE asset_id = ?",
                    arguments: [assetID.rawValue]
                )
                for (index, chunk) in chunks.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO text_span (asset_id, chunk_index, text, script)
                            VALUES (?, ?, ?, ?)
                            """,
                        arguments: [
                            assetID.rawValue,
                            index,
                            chunk.text,
                            chunk.script.rawValue,
                        ]
                    )
                }
            }
        } catch {
            throw LibraryError.databaseOperationFailed("replace text chunks")
        }
    }

    /// Reads text chunks in their original document order for semantic embedding.
    public func textChunks(for assetID: AssetID) async throws -> [String] {
        do {
            return try await database.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT text FROM text_span
                        WHERE asset_id = ?
                        ORDER BY chunk_index ASC
                        """,
                    arguments: [assetID.rawValue]
                )
            }
        } catch {
            throw LibraryError.databaseOperationFailed("read text chunks")
        }
    }
}
