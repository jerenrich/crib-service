-- Per-destination results prevent a retry from replaying an accepted push.
-- Existing completed alerts are left untouched; new claims snapshot both tokens.
ALTER TABLE events ADD COLUMN delivery_state TEXT;
ALTER TABLE connection_notices ADD COLUMN delivery_state TEXT;
