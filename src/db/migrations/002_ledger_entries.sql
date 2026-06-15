# Updated: 2026-06-15T16:56:49Z
CREATE TABLE ledger_entries (
  id BIGSERIAL PRIMARY KEY,
  txn_id UUID NOT NULL,
  entry_hash CHAR(64) NOT NULL,
  prev_hash CHAR(64),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

