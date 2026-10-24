ALTER TABLE devices ADD COLUMN alerts_muted_until INTEGER NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN alerts_muted_at INTEGER NOT NULL DEFAULT 0;
-- Preserve each saved crying threshold; replace the retired reminder choices.
UPDATE devices SET config=json_set(config,'$.repeatInterval',15,'$.snoozeDuration',60);
-- Existing connection-alert preferences remain unchanged. New registrations opt in.
CREATE INDEX episode_acknowledgements ON events(parent_id,episode_id,acknowledged_at);

ALTER TABLE events ADD COLUMN reminder_of TEXT;
CREATE UNIQUE INDEX one_reminder_per_event ON events(reminder_of) WHERE reminder_of IS NOT NULL;
