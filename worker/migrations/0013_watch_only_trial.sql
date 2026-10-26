-- Pin the trial route on first claim. Configuration changes must not turn a
-- single-target retry into dual delivery or replay an accepted destination.
ALTER TABLE events ADD COLUMN delivery_mode TEXT CHECK(delivery_mode IS NULL OR delivery_mode='watch_only');
