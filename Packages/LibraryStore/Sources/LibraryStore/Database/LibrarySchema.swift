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
        migrator.registerMigration("v3-missing-media") { db in
            try db.alter(table: "asset") { table in
                table.add(column: "missing_since", .double)
            }
        }
        migrator.registerMigration("v4-search-index-jobs") { db in
            try db.execute(
                sql: """
                    CREATE TABLE index_job (
                      asset_id   TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                      stage      TEXT NOT NULL,
                      state      TEXT NOT NULL CHECK (
                        state IN ('pending', 'running', 'done', 'failed', 'skipped')
                      ),
                      attempts   INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
                      error      TEXT,
                      updated_at REAL NOT NULL,
                      PRIMARY KEY (asset_id, stage)
                    );
                    CREATE INDEX idx_index_job_schedule
                      ON index_job(state, updated_at, stage);
                    """
            )
        }
        migrator.registerMigration("v5-search-ocr") { db in
            try db.execute(
                sql: """
                    CREATE TABLE ocr_span (
                      id          INTEGER PRIMARY KEY AUTOINCREMENT,
                      asset_id    TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                      start_value INTEGER,
                      start_scale INTEGER,
                      end_value   INTEGER,
                      end_scale   INTEGER,
                      text        TEXT NOT NULL,
                      bbox        TEXT NOT NULL,
                      confidence  REAL NOT NULL,
                      revision    INTEGER NOT NULL,
                      script      TEXT NOT NULL
                    );
                    CREATE INDEX idx_ocr_asset ON ocr_span(asset_id);
                    CREATE INDEX idx_ocr_revision ON ocr_span(revision);

                    CREATE VIRTUAL TABLE ocr_fts USING fts5(
                      text,
                      content='ocr_span',
                      content_rowid='id',
                      tokenize='unicode61 remove_diacritics 2'
                    );
                    CREATE VIRTUAL TABLE ocr_fts_cjk USING fts5(
                      text,
                      content='ocr_span',
                      content_rowid='id',
                      tokenize='trigram'
                    );

                    CREATE TRIGGER ocr_fts_insert AFTER INSERT ON ocr_span
                    WHEN new.script IN ('alphabetic', 'mixed') BEGIN
                      INSERT INTO ocr_fts(rowid, text) VALUES (new.id, new.text);
                    END;
                    CREATE TRIGGER ocr_fts_delete AFTER DELETE ON ocr_span
                    WHEN old.script IN ('alphabetic', 'mixed') BEGIN
                      INSERT INTO ocr_fts(ocr_fts, rowid, text)
                      VALUES ('delete', old.id, old.text);
                    END;
                    CREATE TRIGGER ocr_fts_cjk_insert AFTER INSERT ON ocr_span
                    WHEN new.script IN ('cjk', 'mixed') BEGIN
                      INSERT INTO ocr_fts_cjk(rowid, text) VALUES (new.id, new.text);
                    END;
                    CREATE TRIGGER ocr_fts_cjk_delete AFTER DELETE ON ocr_span
                    WHEN old.script IN ('cjk', 'mixed') BEGIN
                      INSERT INTO ocr_fts_cjk(ocr_fts_cjk, rowid, text)
                      VALUES ('delete', old.id, old.text);
                    END;
                    """
            )
        }
        migrator.registerMigration("v6-search-keywords") { db in
            try db.execute(
                sql: """
                    CREATE TABLE transcript_span (
                      id          INTEGER PRIMARY KEY AUTOINCREMENT,
                      asset_id    TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                      start_value INTEGER NOT NULL,
                      start_scale INTEGER NOT NULL,
                      end_value   INTEGER NOT NULL,
                      end_scale   INTEGER NOT NULL,
                      text        TEXT NOT NULL,
                      script      TEXT NOT NULL
                    );
                    CREATE INDEX idx_transcript_asset ON transcript_span(asset_id);

                    CREATE VIRTUAL TABLE transcript_fts USING fts5(
                      text,
                      content='transcript_span',
                      content_rowid='id',
                      tokenize='unicode61 remove_diacritics 2'
                    );
                    CREATE VIRTUAL TABLE transcript_fts_cjk USING fts5(
                      text,
                      content='transcript_span',
                      content_rowid='id',
                      tokenize='trigram'
                    );
                    CREATE TRIGGER transcript_fts_insert AFTER INSERT ON transcript_span
                    WHEN new.script IN ('alphabetic', 'mixed') BEGIN
                      INSERT INTO transcript_fts(rowid, text) VALUES (new.id, new.text);
                    END;
                    CREATE TRIGGER transcript_fts_delete AFTER DELETE ON transcript_span
                    WHEN old.script IN ('alphabetic', 'mixed') BEGIN
                      INSERT INTO transcript_fts(transcript_fts, rowid, text)
                      VALUES ('delete', old.id, old.text);
                    END;
                    CREATE TRIGGER transcript_fts_cjk_insert AFTER INSERT ON transcript_span
                    WHEN new.script IN ('cjk', 'mixed') BEGIN
                      INSERT INTO transcript_fts_cjk(rowid, text) VALUES (new.id, new.text);
                    END;
                    CREATE TRIGGER transcript_fts_cjk_delete AFTER DELETE ON transcript_span
                    WHEN old.script IN ('cjk', 'mixed') BEGIN
                      INSERT INTO transcript_fts_cjk(transcript_fts_cjk, rowid, text)
                      VALUES ('delete', old.id, old.text);
                    END;

                    CREATE VIRTUAL TABLE asset_fts USING fts5(
                      asset_id UNINDEXED,
                      display_name,
                      relative_path,
                      tokenize='unicode61 remove_diacritics 2'
                    );
                    CREATE TRIGGER asset_fts_insert AFTER INSERT ON asset BEGIN
                      INSERT INTO asset_fts(asset_id, display_name, relative_path)
                      VALUES (new.id, new.display_name, new.relative_path);
                    END;
                    CREATE TRIGGER asset_fts_update AFTER UPDATE OF display_name, relative_path
                    ON asset BEGIN
                      DELETE FROM asset_fts WHERE asset_id = old.id;
                      INSERT INTO asset_fts(asset_id, display_name, relative_path)
                      VALUES (new.id, new.display_name, new.relative_path);
                    END;
                    CREATE TRIGGER asset_fts_delete AFTER DELETE ON asset BEGIN
                      DELETE FROM asset_fts WHERE asset_id = old.id;
                    END;
                    INSERT INTO asset_fts(asset_id, display_name, relative_path)
                    SELECT id, display_name, relative_path FROM asset;
                    """
            )
        }
        migrator.registerMigration("v7-search-embeddings") { db in
            try db.execute(
                sql: """
                    CREATE TABLE embedding (
                      asset_id    TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                      chunk_index INTEGER NOT NULL,
                      kind        TEXT NOT NULL,
                      start_value INTEGER,
                      start_scale INTEGER,
                      end_value   INTEGER,
                      end_scale   INTEGER,
                      text        TEXT NOT NULL,
                      vector      BLOB NOT NULL,
                      dims        INTEGER NOT NULL CHECK (dims > 0),
                      model       TEXT NOT NULL,
                      PRIMARY KEY (asset_id, chunk_index, kind, model)
                    );
                    CREATE INDEX idx_embedding_model ON embedding(model, asset_id);
                    INSERT OR IGNORE INTO meta (key, value)
                    VALUES ('embeddingGeneration', '0');
                    """
            )
        }
        try migrator.migrate(database)
    }
}
