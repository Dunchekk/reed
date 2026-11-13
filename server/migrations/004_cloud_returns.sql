CREATE TABLE cloud_return_plans (
    account_id uuid PRIMARY KEY REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
    sequence bigint NOT NULL, day_key text NOT NULL, time_zone text NOT NULL, issue text
);
CREATE TABLE cloud_return_days (
    account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
    day_key text NOT NULL, seed text NOT NULL, PRIMARY KEY(account_id,day_key)
);
CREATE TABLE cloud_return_slots (
    account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
    id text NOT NULL, scheduled_at timestamptz NOT NULL, slot jsonb NOT NULL, decision jsonb NOT NULL,
    revision uuid NOT NULL, cancelled boolean NOT NULL DEFAULT false,
    PRIMARY KEY(account_id,id)
);
CREATE INDEX cloud_return_due ON cloud_return_slots(scheduled_at) WHERE NOT cancelled;
