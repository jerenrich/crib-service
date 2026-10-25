-- Per-invocation ownership lets a SELECT prove that one original claim committed
-- when its binding reply is delayed. No additional claim/write is issued.
ALTER TABLE events ADD COLUMN claim_id TEXT;
