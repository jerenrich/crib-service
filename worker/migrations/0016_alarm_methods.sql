-- Per-Parent AlarmKit delivery methods for on-device comparison. The app
-- background wake keeps its existing behaviour; the notification extension is
-- opt-in.
ALTER TABLE devices ADD COLUMN alarm_app_wake INTEGER NOT NULL DEFAULT 1;
ALTER TABLE devices ADD COLUMN alarm_extension INTEGER NOT NULL DEFAULT 0;
