-- Resolution is separate from a parent's explicit acknowledgement/snooze.
ALTER TABLE events ADD COLUMN resolved_at TEXT;
CREATE TABLE resolved_episodes (
 parent_id TEXT NOT NULL, listener_id TEXT NOT NULL, pair_created_at INTEGER NOT NULL,
 episode_id TEXT NOT NULL, resolved_at TEXT NOT NULL,
 PRIMARY KEY(parent_id, listener_id, pair_created_at, episode_id)
);
CREATE INDEX unresolved_parent_events ON events(parent_id, listener_id, episode_id)
 WHERE resolved_at IS NULL AND acknowledged_at IS NULL;
