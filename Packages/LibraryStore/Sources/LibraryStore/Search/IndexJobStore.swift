import CoreModel
import Foundation
import GRDB

extension LibraryStore {
    /// Adds missing jobs without restarting stages that have already finished.
    public func enqueueIndexJobs(
        for assetID: AssetID,
        stages: Set<IndexStage>
    ) async throws {
        guard !stages.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        do {
            try await database.write { db in
                for stage in stages.sorted(by: { $0.order < $1.order }) {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO index_job
                              (asset_id, stage, state, attempts, error, updated_at)
                            VALUES (?, ?, 'pending', 0, NULL, ?)
                            """,
                        arguments: [assetID.rawValue, stage.rawValue, now]
                    )
                }
            }
        } catch {
            throw LibraryError.databaseOperationFailed("enqueue index jobs")
        }
    }

    /// Restores work that was interrupted by a process exit without counting it as a failure.
    public func resetInterruptedIndexJobs() async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                        UPDATE index_job
                        SET state = 'pending', error = NULL, updated_at = ?
                        WHERE state = 'running'
                        """,
                    arguments: [Date().timeIntervalSince1970]
                )
            }
        } catch {
            throw LibraryError.databaseOperationFailed("resume interrupted index jobs")
        }
    }

    /// Atomically claims the oldest pending job in dependency order.
    public func claimNextIndexJob(allowSummary: Bool = true) async throws -> IndexJobRecord? {
        do {
            return try await database.write { db in
                guard
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT asset_id, stage, state, attempts, error, updated_at
                            FROM index_job
                            WHERE state = 'pending'
                              AND attempts < 3
                              AND (? OR stage != 'summary')
                            ORDER BY
                              CASE stage
                                WHEN 'metadata' THEN 0
                                WHEN 'ocr' THEN 1
                                WHEN 'transcript' THEN 2
                                WHEN 'embedding' THEN 3
                                ELSE 4
                              END,
                              updated_at ASC,
                              asset_id ASC
                            LIMIT 1
                            """,
                        arguments: [allowSummary]
                    ),
                    let job = Self.decodeIndexJob(row)
                else { return nil }
                try db.execute(
                    sql: """
                        UPDATE index_job
                        SET state = 'running', error = NULL, updated_at = ?
                        WHERE asset_id = ? AND stage = ? AND state = 'pending'
                        """,
                    arguments: [
                        Date().timeIntervalSince1970,
                        job.assetID.rawValue,
                        job.stage.rawValue,
                    ]
                )
                guard db.changesCount == 1 else { return nil }
                var claimed = job
                claimed.state = .running
                claimed.error = nil
                claimed.updatedAt = .now
                return claimed
            }
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.databaseOperationFailed("claim index job")
        }
    }

    /// Marks a running job as complete or legitimately empty.
    public func finishIndexJob(
        assetID: AssetID,
        stage: IndexStage,
        outcome: IndexJobState
    ) async throws {
        guard outcome == .done || outcome == .skipped else {
            throw LibraryError.databaseOperationFailed("invalid index job outcome")
        }
        try await updateIndexJob(
            assetID: assetID,
            stage: stage,
            state: outcome,
            error: nil,
            incrementsAttempts: false
        )
    }

    /// Records a failed attempt, retrying twice before making the failure terminal.
    @discardableResult
    public func failIndexJob(
        assetID: AssetID,
        stage: IndexStage,
        error message: String
    ) async throws -> IndexJobState {
        do {
            return try await database.write { db in
                let attempts =
                    try Int.fetchOne(
                        db,
                        sql: "SELECT attempts FROM index_job WHERE asset_id = ? AND stage = ?",
                        arguments: [assetID.rawValue, stage.rawValue]
                    ) ?? 0
                let nextAttempts = attempts + 1
                let nextState: IndexJobState = nextAttempts >= 3 ? .failed : .pending
                try db.execute(
                    sql: """
                        UPDATE index_job
                        SET state = ?, attempts = ?, error = ?, updated_at = ?
                        WHERE asset_id = ? AND stage = ?
                        """,
                    arguments: [
                        nextState.rawValue,
                        nextAttempts,
                        message,
                        Date().timeIntervalSince1970,
                        assetID.rawValue,
                        stage.rawValue,
                    ]
                )
                return nextState
            }
        } catch {
            throw LibraryError.databaseOperationFailed("record index job failure")
        }
    }

    /// Returns all jobs in deterministic order for progress, diagnostics, and tests.
    public func indexJobs() async throws -> [IndexJobRecord] {
        do {
            return try await database.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT asset_id, stage, state, attempts, error, updated_at
                        FROM index_job
                        ORDER BY updated_at ASC, asset_id ASC, stage ASC
                        """
                ).compactMap(Self.decodeIndexJob)
            }
        } catch {
            throw LibraryError.databaseOperationFailed("list index jobs")
        }
    }

    /// Removes and recreates selected jobs while keeping asset identity stable.
    public func rebuildIndexJobs(scope: IndexScope, stages: Set<IndexStage>) async throws {
        guard !stages.isEmpty else { return }
        let stageValues = stages.map(\.rawValue)
        do {
            try await database.write { db in
                let assets: [String]
                switch scope {
                case .all:
                    assets = try String.fetchAll(db, sql: "SELECT id FROM asset ORDER BY id")
                case .assets(let ids):
                    assets = ids.map(\.rawValue).sorted()
                }
                for assetID in assets {
                    for stage in stageValues {
                        try db.execute(
                            sql: "DELETE FROM index_job WHERE asset_id = ? AND stage = ?",
                            arguments: [assetID, stage]
                        )
                        try db.execute(
                            sql: """
                                INSERT INTO index_job
                                  (asset_id, stage, state, attempts, error, updated_at)
                                VALUES (?, ?, 'pending', 0, NULL, ?)
                                """,
                            arguments: [assetID, stage, Date().timeIntervalSince1970]
                        )
                    }
                }
            }
        } catch {
            throw LibraryError.databaseOperationFailed("rebuild index jobs")
        }
    }

    /// Cancels queued work for one asset. Durable index rows added by later stages
    /// are deliberately left alone; missing media must remain searchable.
    public func cancelIndexJobs(for assetID: AssetID) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM index_job WHERE asset_id = ?",
                    arguments: [assetID.rawValue]
                )
            }
        } catch {
            throw LibraryError.databaseOperationFailed("cancel index jobs")
        }
    }

    private func updateIndexJob(
        assetID: AssetID,
        stage: IndexStage,
        state: IndexJobState,
        error: String?,
        incrementsAttempts: Bool
    ) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                        UPDATE index_job
                        SET state = ?, attempts = attempts + ?, error = ?, updated_at = ?
                        WHERE asset_id = ? AND stage = ?
                        """,
                    arguments: [
                        state.rawValue,
                        incrementsAttempts ? 1 : 0,
                        error,
                        Date().timeIntervalSince1970,
                        assetID.rawValue,
                        stage.rawValue,
                    ]
                )
            }
        } catch {
            throw LibraryError.databaseOperationFailed("update index job")
        }
    }

    private nonisolated static func decodeIndexJob(_ row: Row) -> IndexJobRecord? {
        guard
            let assetRaw: String = row["asset_id"],
            let stage = IndexStage(rawValue: row["stage"] as String),
            let state = IndexJobState(rawValue: row["state"] as String)
        else { return nil }
        return IndexJobRecord(
            assetID: AssetID(rawValue: assetRaw),
            stage: stage,
            state: state,
            attempts: row["attempts"],
            error: row["error"],
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }
}
