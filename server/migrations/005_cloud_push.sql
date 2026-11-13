ALTER TABLE cloud_devices ADD COLUMN is_ready boolean NOT NULL DEFAULT false;
ALTER TABLE cloud_devices ADD COLUMN suspended boolean NOT NULL DEFAULT false;
CREATE TABLE cloud_push_outbox (
  account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
  slot_id text NOT NULL, attempt_id uuid NOT NULL, device_id uuid,
  state text NOT NULL CHECK(state IN ('sending','accepted','rejected','unknown','retry','skipped')),
  updated_at timestamptz NOT NULL DEFAULT now(), retry_at timestamptz,
  PRIMARY KEY(account_id,slot_id)
);
