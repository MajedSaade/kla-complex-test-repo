# Updated: 2026-06-15T16:56:49Z
-- WI-440219: advisory locks to prevent concurrent payment writes
ALTER TABLE payments ADD COLUMN lock_token UUID;
CREATE INDEX idx_payments_lock_token ON payments(lock_token);

