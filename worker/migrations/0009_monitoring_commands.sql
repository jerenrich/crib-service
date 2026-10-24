CREATE TABLE monitoring_commands (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 id TEXT NOT NULL UNIQUE,
 claim_id TEXT NOT NULL,
 parent_id TEXT NOT NULL REFERENCES devices(id),
 listener_id TEXT NOT NULL REFERENCES devices(id),
 pair_created_at INTEGER NOT NULL,
 enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
 status TEXT NOT NULL CHECK(status IN ('pending','applied','failed')),
 created_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL
);
CREATE INDEX monitoring_commands_pair ON monitoring_commands(parent_id,listener_id,pair_created_at,sequence DESC);
