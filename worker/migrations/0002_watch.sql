ALTER TABLE devices ADD COLUMN watch_push_token TEXT;
-- Pin the destination so a retry never replays an accepted alert elsewhere.
ALTER TABLE events ADD COLUMN push_target TEXT CHECK(push_target IN ('phone','watch'));
