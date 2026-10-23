ALTER TABLE devices ADD COLUMN connection_alerts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pairs ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;
CREATE TABLE connection_states (
 listener_id TEXT PRIMARY KEY REFERENCES devices(id),
 state TEXT NOT NULL CHECK(state IN ('online','offline','stopped')),
 changed_at TEXT NOT NULL
);
CREATE TABLE connection_notices (
 id TEXT PRIMARY KEY, listener_id TEXT NOT NULL REFERENCES devices(id),
 parent_id TEXT NOT NULL REFERENCES devices(id), state TEXT NOT NULL,
 observed_at TEXT NOT NULL, created_at INTEGER NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
 next_attempt INTEGER NOT NULL DEFAULT 0, lease_until INTEGER,
 UNIQUE(listener_id,state,observed_at)
);
