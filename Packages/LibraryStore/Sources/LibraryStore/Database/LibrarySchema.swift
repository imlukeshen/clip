import GRDB

enum LibrarySchema {
    static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE asset (
                      id                TEXT PRIMARY KEY,
                      relative_path     TEXT NOT NULL UNIQUE,
                      display_name      TEXT NOT NULL,
                      kind              TEXT NOT NULL,
                      container         TEXT,
                      codec             TEXT,
                      created_at        REAL NOT NULL,
                      imported_at       REAL NOT NULL,
                      byte_size         INTEGER NOT NULL,
                      content_hash      TEXT NOT NULL,
                      width             INTEGER,
                      height            INTEGER,
                      duration_value    INTEGER,
                      duration_scale    INTEGER,
                      nominal_fps       REAL,
                      is_variable_fps   INTEGER NOT NULL DEFAULT 0,
                      has_audio         INTEGER NOT NULL DEFAULT 0,
                      preferred_xform   TEXT,
                      event_track_path  TEXT,
                      event_alignment   TEXT,
                      thumb_path        TEXT,
                      peaks_path        TEXT,
                      ingest_state      TEXT NOT NULL
                    );
                    CREATE INDEX idx_asset_created ON asset(created_at DESC);
                    CREATE UNIQUE INDEX idx_asset_hash ON asset(content_hash);

                    CREATE TABLE project (
                      id              TEXT PRIMARY KEY,
                      name            TEXT NOT NULL,
                      package_path    TEXT NOT NULL UNIQUE,
                      modified_at     REAL NOT NULL,
                      duration_value  INTEGER NOT NULL,
                      duration_scale  INTEGER NOT NULL,
                      item_count      INTEGER NOT NULL
                    );

                    CREATE TABLE project_asset (
                      project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                      asset_id   TEXT NOT NULL REFERENCES asset(id),
                      PRIMARY KEY (project_id, asset_id)
                    );

                    CREATE TABLE egress_log (
                      id             INTEGER PRIMARY KEY AUTOINCREMENT,
                      at             REAL NOT NULL,
                      provider       TEXT NOT NULL,
                      host           TEXT NOT NULL,
                      model          TEXT,
                      purpose        TEXT NOT NULL,
                      request_bytes  INTEGER NOT NULL,
                      response_bytes INTEGER NOT NULL,
                      media_attached INTEGER NOT NULL,
                      turn_id        TEXT,
                      error          TEXT
                    );
                    CREATE INDEX idx_egress_at ON egress_log(at DESC);

                    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    """
            )
        }
        migrator.registerMigration("v2-library-layout") { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('schemaVersion', ?)",
                arguments: [LibraryLayout.schemaVersion]
            )
        }
        try migrator.migrate(database)
    }
}
