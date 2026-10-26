-- Only updated Parents opt into bounded AlarmKit wake requests.
ALTER TABLE devices ADD COLUMN alarm_receipts_version INTEGER NOT NULL DEFAULT 0 CHECK(alarm_receipts_version IN (0,1));
CREATE TABLE silent_alarm_cycles (
 parent_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 episode_id TEXT NOT NULL,
 listener_id TEXT NOT NULL,
 pair_created_at INTEGER NOT NULL,
 cycle_at INTEGER NOT NULL,
 cycle_id TEXT NOT NULL,
 first_requested_at INTEGER NOT NULL,
 last_requested_at INTEGER NOT NULL,
 request_count INTEGER NOT NULL CHECK(request_count BETWEEN 1 AND 3),
 request_claim_id TEXT NOT NULL,
 request_event_ids TEXT NOT NULL,
 confirmed_at INTEGER,
 PRIMARY KEY(parent_id,episode_id)
);
