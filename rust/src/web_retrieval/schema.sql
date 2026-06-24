-- HavenChat web-retrieval cache schema.
-- Single file, namespaced tables. FTS5 external-content tables index the
-- base tables to avoid duplicating content in the index.

-- ---------------------------------------------------------------------------
-- Fetched pages (URL -> content cache)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS web_pages (
    url            TEXT PRIMARY KEY,
    title          TEXT NOT NULL DEFAULT '',
    content        TEXT NOT NULL DEFAULT '',
    content_type   TEXT NOT NULL DEFAULT '',
    etag           TEXT,
    last_modified  TEXT,
    fetched_at     INTEGER NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS web_pages_fts USING fts5(
    url, title, content,
    tokenize = 'unicode61',
    content = 'web_pages',
    content_rowid = 'rowid'
);

CREATE TRIGGER IF NOT EXISTS web_pages_ai AFTER INSERT ON web_pages BEGIN
    INSERT INTO web_pages_fts(rowid, url, title, content)
    VALUES (new.rowid, new.url, new.title, new.content);
END;

CREATE TRIGGER IF NOT EXISTS web_pages_ad AFTER DELETE ON web_pages BEGIN
    INSERT INTO web_pages_fts(web_pages_fts, rowid, url, title, content)
    VALUES ('delete', old.rowid, old.url, old.title, old.content);
END;

CREATE TRIGGER IF NOT EXISTS web_pages_au AFTER UPDATE ON web_pages BEGIN
    INSERT INTO web_pages_fts(web_pages_fts, rowid, url, title, content)
    VALUES ('delete', old.rowid, old.url, old.title, old.content);
    INSERT INTO web_pages_fts(rowid, url, title, content)
    VALUES (new.rowid, new.url, new.title, new.content);
END;

-- ---------------------------------------------------------------------------
-- Search results cache (query + provider -> results)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS web_searches (
    query          TEXT NOT NULL,
    provider       TEXT NOT NULL,
    results_json   TEXT NOT NULL,
    searched_at    INTEGER NOT NULL,
    PRIMARY KEY (query, provider)
) WITHOUT ROWID;

CREATE VIRTUAL TABLE IF NOT EXISTS web_searches_fts USING fts5(
    query, results_json,
    tokenize = 'unicode61',
    content = 'web_searches'
);

CREATE TRIGGER IF NOT EXISTS web_searches_ai AFTER INSERT ON web_searches BEGIN
    INSERT INTO web_searches_fts(rowid, query, results_json)
    VALUES (new.rowid, new.query, new.results_json);
END;

CREATE TRIGGER IF NOT EXISTS web_searches_ad AFTER DELETE ON web_searches BEGIN
    INSERT INTO web_searches_fts(web_searches_fts, rowid, query, results_json)
    VALUES ('delete', old.rowid, old.query, old.results_json);
END;

CREATE TRIGGER IF NOT EXISTS web_searches_au AFTER UPDATE ON web_searches BEGIN
    INSERT INTO web_searches_fts(web_searches_fts, rowid, query, results_json)
    VALUES ('delete', old.rowid, old.query, old.results_json);
    INSERT INTO web_searches_fts(rowid, query, results_json)
    VALUES (new.rowid, new.query, new.results_json);
END;

-- ---------------------------------------------------------------------------
-- Provider quota tracking (rate-limit awareness)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS web_provider_quota (
    provider     TEXT PRIMARY KEY,
    used_today   INTEGER NOT NULL DEFAULT 0,
    reset_at     INTEGER
);

-- Schema version marker.
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER NOT NULL
);
INSERT OR IGNORE INTO schema_version (version) VALUES (1);
