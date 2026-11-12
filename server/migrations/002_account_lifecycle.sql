ALTER TABLE accounts ALTER COLUMN phone DROP NOT NULL;
ALTER TABLE accounts ADD COLUMN recovery_email text;
ALTER TABLE accounts ADD COLUMN deletion_status text NOT NULL DEFAULT 'active'
  CHECK (deletion_status IN ('active', 'pending', 'deleted'));
CREATE TABLE account_contact_changes (
  account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('phone', 'email')),
  value text NOT NULL,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '1 hour',
  PRIMARY KEY (account_id, kind)
);
CREATE TABLE development_identities (
  subject text PRIMARY KEY,
  phone text NOT NULL UNIQUE,
  email text UNIQUE
);
INSERT INTO development_identities (subject, phone)
  SELECT provider_subject, phone FROM accounts WHERE provider='development'
  ON CONFLICT DO NOTHING;
