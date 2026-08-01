import CoreModel
import Foundation
import GRDB

extension AssetRecord {
    static func fetchOne(_ db: Database, id: AssetID) throws -> AssetRecord? {
        let row = try Row.fetchOne(
            db, sql: "SELECT * FROM asset WHERE id = ?", arguments: [id.rawValue])
        return try row.map(fromDatabaseRow)
    }

    static func fetchOne(_ db: Database, contentHash: String) throws -> AssetRecord? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM asset WHERE content_hash = ?",
            arguments: [contentHash]
        )
        return try row.map(fromDatabaseRow)
    }

    static func fetchAll(
        _ db: Database,
        kind: AssetKind?,
        limit: Int,
        offset: Int
    ) throws -> [AssetRecord] {
        let rows: [Row]
        if let kind {
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM asset
                    WHERE kind = ?
                    ORDER BY created_at DESC, id ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [kind.rawValue, limit, offset]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM asset
                    ORDER BY created_at DESC, id ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [limit, offset]
            )
        }
        return try rows.map(fromDatabaseRow)
    }

    func insert(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO asset (
                  id, relative_path, display_name, kind, container, codec,
                  created_at, imported_at, byte_size, content_hash, width, height,
                  duration_value, duration_scale, nominal_fps, is_variable_fps,
                  has_audio, preferred_xform, event_track_path, event_alignment,
                  thumb_path, peaks_path, ingest_state
                ) VALUES (
                  ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                )
                """,
            arguments: [
                id.rawValue,
                relativePath,
                displayName,
                kind.rawValue,
                container,
                codec,
                createdAt.timeIntervalSince1970,
                importedAt.timeIntervalSince1970,
                byteSize,
                contentHash,
                width,
                height,
                duration?.value,
                duration?.timescale,
                nominalFPS,
                isVariableFPS,
                hasAudio,
                try MetadataCodec.encodeJSONValue(preferredTransform),
                eventTrackPath,
                eventAlignment?.rawValue,
                thumbnailPath,
                peaksPath,
                ingestState.rawValue,
            ]
        )
    }

    private static func fromDatabaseRow(_ row: Row) throws -> AssetRecord {
        let kindValue: String = row["kind"]
        let stateValue: String = row["ingest_state"]
        guard let kind = AssetKind(rawValue: kindValue),
            let ingestState = IngestState(rawValue: stateValue)
        else {
            throw LibraryError.corruptMetadata("asset enum")
        }
        let durationValue: Int64? = row["duration_value"]
        let durationScale: Int32? = row["duration_scale"]
        let alignmentValue: String? = row["event_alignment"]
        let alignment = try alignmentValue.map { rawValue in
            guard let value = EventAlignmentKind(rawValue: rawValue) else {
                throw LibraryError.corruptMetadata("event alignment")
            }
            return value
        }
        let duration: RationalTime?
        switch (durationValue, durationScale) {
        case (.none, .none):
            duration = nil
        case (.some(let value), .some(let scale)):
            duration = RationalTime(value: value, timescale: scale)
        default:
            throw LibraryError.corruptMetadata("asset duration")
        }

        return AssetRecord(
            id: AssetID(rawValue: row["id"]),
            relativePath: row["relative_path"],
            displayName: row["display_name"],
            kind: kind,
            container: row["container"],
            codec: row["codec"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            importedAt: Date(timeIntervalSince1970: row["imported_at"]),
            byteSize: row["byte_size"],
            contentHash: row["content_hash"],
            width: row["width"],
            height: row["height"],
            duration: duration,
            nominalFPS: row["nominal_fps"],
            isVariableFPS: row["is_variable_fps"],
            hasAudio: row["has_audio"],
            preferredTransform: try MetadataCodec.decodeJSONValue(row["preferred_xform"]),
            eventTrackPath: row["event_track_path"],
            eventAlignment: alignment,
            thumbnailPath: row["thumb_path"],
            peaksPath: row["peaks_path"],
            ingestState: ingestState
        )
    }
}
