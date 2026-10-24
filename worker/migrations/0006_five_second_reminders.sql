-- Keep crying thresholds, snooze durations and connection preferences unchanged.
UPDATE devices SET config=json_set(config,'$.repeatInterval',5);
