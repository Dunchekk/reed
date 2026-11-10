CREATE TABLE accounts (
  id uuid PRIMARY KEY,
  provider text NOT NULL,
  provider_subject text NOT NULL,
  phone text NOT NULL CHECK (phone ~ '^\+7[0-9]{10}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_subject)
);
