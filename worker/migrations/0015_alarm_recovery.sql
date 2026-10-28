-- Recover throughout an unresolved episode; keep existing receipts and cycles.
-- SQLite cannot remove the old three-request CHECK constraint in place.
CREATE TABLE silent_alarm_cycles_recovery (
 parent_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 episode_id TEXT NOT NULL,
 listener_id TEXT NOT NULL,
 pair_created_at INTEGER NOT NULL,
 cycle_at INTEGER NOT NULL,
 cycle_id TEXT NOT NULL,
 first_requested_at INTEGER NOT NULL,
 last_requested_at INTEGER NOT NULL,
 request_count INTEGER NOT NULL CHECK(request_count>=1),
 request_claim_id TEXT NOT NULL,
 request_event_ids TEXT NOT NULL,
 confirmed_at INTEGER,
 PRIMARY KEY(parent_id,episode_id)
);
INSERT INTO silent_alarm_cycles_recovery SELECT * FROM silent_alarm_cycles;
DROP TABLE silent_alarm_cycles;
ALTER TABLE silent_alarm_cycles_recovery RENAME TO silent_alarm_cycles;
