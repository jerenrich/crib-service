-- Keep every snooze through the 24-hour offline-alert delivery window. The
-- per-request claim also makes acknowledgement side effects atomic/idempotent.
CREATE TABLE alert_snoozes (
 event_id TEXT PRIMARY KEY, claim_id TEXT NOT NULL,
 parent_id TEXT NOT NULL REFERENCES devices(id),
 listener_id TEXT NOT NULL REFERENCES devices(id), pair_created_at INTEGER NOT NULL,
 started_at INTEGER NOT NULL, until_at INTEGER NOT NULL
);
CREATE INDEX snooze_windows ON alert_snoozes(parent_id, listener_id, pair_created_at, until_at);
-- Preserve the last known interval when upgrading an existing installation.
INSERT INTO alert_snoozes
 SELECT 'legacy:' || d.id, 'migration', d.id, p.listener_id, p.created_at,
 d.alerts_muted_at, d.alerts_muted_until
 FROM devices d JOIN pairs p ON p.parent_id=d.id WHERE d.alerts_muted_until>0;
