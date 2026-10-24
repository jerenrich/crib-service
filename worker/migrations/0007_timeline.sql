CREATE TABLE timeline_events (
 id TEXT NOT NULL, parent_id TEXT NOT NULL REFERENCES devices(id),
 listener_id TEXT NOT NULL REFERENCES devices(id), pair_created_at INTEGER NOT NULL,
 kind TEXT NOT NULL, occurred_at INTEGER NOT NULL, payload TEXT NOT NULL,
 PRIMARY KEY(parent_id, listener_id, pair_created_at, id)
);
CREATE INDEX timeline_window ON timeline_events(parent_id, listener_id, pair_created_at, occurred_at);
CREATE TABLE timeline_metadata (id INTEGER PRIMARY KEY CHECK(id=1), available_since INTEGER NOT NULL);
INSERT INTO timeline_metadata VALUES(1, CAST(strftime('%s','now') AS INTEGER)*1000);
ALTER TABLE connection_notices ADD COLUMN sent_at TEXT;
