ALTER TABLE devices ADD COLUMN caregiver_name TEXT NOT NULL DEFAULT 'Caregiver';
ALTER TABLE devices ADD COLUMN alerts_muted_by TEXT;
ALTER TABLE devices ADD COLUMN secondary_enabled INTEGER NOT NULL DEFAULT 1;
CREATE TABLE caregiver_families (
 owner_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
 partner_id TEXT UNIQUE REFERENCES devices(id) ON DELETE CASCADE,
 pair_created_at INTEGER NOT NULL,
 primary_id TEXT NOT NULL REFERENCES devices(id),
 escalation_seconds INTEGER NOT NULL DEFAULT 120 CHECK(escalation_seconds IN (60,120,180,300)),
 mutation_id TEXT,
 revision INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE caregiver_invites (
 code_hash TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 pair_created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, claimed_by TEXT REFERENCES devices(id)
);
ALTER TABLE events ADD COLUMN caregiver_plan TEXT;
CREATE TABLE caregiver_deliveries (
 event_id TEXT NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
 device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 target TEXT NOT NULL CHECK(target IN ('phone','watch')),
 state TEXT NOT NULL DEFAULT 'pending', claim_id TEXT, lease_until INTEGER,
 PRIMARY KEY(event_id,device_id,target)
);
