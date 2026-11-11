CREATE TABLE cloud_libraries (
  account_id uuid PRIMARY KEY REFERENCES accounts(id),
  epoch uuid NOT NULL,
  sequence bigint NOT NULL DEFAULT 0 CHECK (sequence BETWEEN 0 AND 9007199254740991),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE cloud_records (
  account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('author','source','folder','tag','card','returnSettings','cardReturn','opening','historyPreference','returnHistory')),
  id text NOT NULL, version bigint NOT NULL CHECK (version>0), sequence bigint NOT NULL,
  payload jsonb, PRIMARY KEY(account_id,kind,id)
);
CREATE INDEX cloud_records_kind ON cloud_records(account_id,kind,sequence);
CREATE TABLE cloud_changes (
  account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
  sequence bigint NOT NULL, kind text NOT NULL, id text NOT NULL,
  version bigint NOT NULL, payload jsonb, PRIMARY KEY(account_id,sequence)
);
CREATE TABLE cloud_operations (
  account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
  operation_id uuid NOT NULL, request_hash text NOT NULL,
  result jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(account_id,operation_id)
);
CREATE TABLE cloud_devices (
  account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
  id uuid NOT NULL, name text NOT NULL, time_zone text NOT NULL,
  is_primary boolean NOT NULL DEFAULT false, push_token text, revoked_at timestamptz,
  last_seen_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(account_id,id)
);
CREATE UNIQUE INDEX cloud_one_primary ON cloud_devices(account_id) WHERE is_primary AND revoked_at IS NULL;
CREATE TABLE cloud_uploads (
  account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
  epoch uuid NOT NULL, id uuid NOT NULL, attachment_id uuid NOT NULL,
  manifest jsonb NOT NULL, original_offset bigint NOT NULL DEFAULT 0,
  thumbnail_offset bigint NOT NULL DEFAULT 0, complete boolean NOT NULL DEFAULT false,
  expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',
  PRIMARY KEY(account_id,id), UNIQUE(account_id,epoch,attachment_id)
);
CREATE TABLE cloud_media (
  account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
  id uuid NOT NULL, manifest jsonb NOT NULL, bytes bigint NOT NULL CHECK(bytes>0),
  created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(account_id,id)
);
