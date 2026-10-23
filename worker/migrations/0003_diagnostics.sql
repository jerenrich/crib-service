-- Operational journal only: no device identity, requests, payloads or exception text.
CREATE TABLE diagnostics (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 recorded_at INTEGER NOT NULL,
 request_id TEXT NOT NULL,
 operation TEXT NOT NULL,
 stage TEXT NOT NULL,
 outcome TEXT NOT NULL,
 http_status INTEGER,
 elapsed_ms INTEGER NOT NULL,
 event_ref TEXT,
 attempt INTEGER,
 target TEXT,
 release TEXT
);
CREATE INDEX diagnostics_time ON diagnostics(recorded_at);
CREATE INDEX diagnostics_request ON diagnostics(request_id);
CREATE INDEX diagnostics_event ON diagnostics(event_ref) WHERE event_ref IS NOT NULL;
-- Hard volume bound in addition to the scheduled time-based expiry.
CREATE TRIGGER diagnostics_bound AFTER INSERT ON diagnostics BEGIN
 DELETE FROM diagnostics WHERE sequence <= NEW.sequence - 10000;
END;
