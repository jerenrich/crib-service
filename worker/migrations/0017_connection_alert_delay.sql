-- Seconds without a Listener update before a connection-loss alert wakes the
-- Parent. Chosen in Settings in whole minutes, 1 to 20; 10 minutes by default.
ALTER TABLE devices ADD COLUMN connection_alert_delay INTEGER NOT NULL DEFAULT 600;
