-- Heartbeat recovery and cron only need outstanding outage episodes.
CREATE INDEX active_listener_disconnects ON events(parent_id,listener_id,episode_id)
 WHERE resolved_at IS NULL AND json_extract(payload,'$.type')='listener_disconnected';
