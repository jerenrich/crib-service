-- Optional additional delivery; ordinary notifications remain independent.
ALTER TABLE devices ADD COLUMN silent_watch_alarms INTEGER NOT NULL DEFAULT 0 CHECK(silent_watch_alarms IN (0,1));
