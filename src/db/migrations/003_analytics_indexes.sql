# Updated: 2026-06-15T16:56:49Z
CREATE INDEX idx_events_timestamp ON analytics_events(timestamp DESC);
CREATE INDEX idx_events_user_ts ON analytics_events(user_id, timestamp DESC);

