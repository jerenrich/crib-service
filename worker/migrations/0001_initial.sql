PRAGMA foreign_keys = ON;
CREATE TABLE devices (
 id TEXT PRIMARY KEY, role TEXT NOT NULL CHECK(role IN ('listener','parent')),
 secret_hash TEXT NOT NULL, push_token TEXT, created_at TEXT NOT NULL,
 config TEXT NOT NULL
);
CREATE TABLE pairs (
 parent_id TEXT PRIMARY KEY REFERENCES devices(id),
 listener_id TEXT NOT NULL UNIQUE REFERENCES devices(id)
);
CREATE TABLE pairing_codes (
 code_hash TEXT PRIMARY KEY, parent_id TEXT NOT NULL UNIQUE REFERENCES devices(id),
 expires_at INTEGER NOT NULL, claimed_by TEXT UNIQUE REFERENCES devices(id)
);
CREATE TABLE rate_limits (key TEXT PRIMARY KEY, window INTEGER NOT NULL, attempts INTEGER NOT NULL);
CREATE TABLE heartbeats (
 listener_id TEXT PRIMARY KEY REFERENCES devices(id), received_at TEXT NOT NULL, metadata TEXT NOT NULL
);
CREATE TABLE events (
 event_id TEXT PRIMARY KEY, episode_id TEXT NOT NULL, listener_id TEXT NOT NULL REFERENCES devices(id),
 parent_id TEXT NOT NULL REFERENCES devices(id), is_repeat INTEGER NOT NULL,
 payload TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','sending','sent','failed','uncertain','blocked')),
 attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0,
 lease_until INTEGER, sent_at TEXT, acknowledged_at TEXT, last_error TEXT,
 created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX one_initial_per_episode ON events(listener_id, episode_id) WHERE is_repeat = 0;
CREATE INDEX pending_events ON events(status, next_attempt);
CREATE INDEX parent_events ON events(parent_id, created_at);
