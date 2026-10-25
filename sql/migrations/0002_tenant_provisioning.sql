CREATE TABLE migration_control.provisioning_receipts (
 request_id uuid PRIMARY KEY,
 input_sha256 text NOT NULL CHECK(input_sha256 ~ '^[a-f0-9]{64}$'),
 receipt jsonb NOT NULL CHECK(jsonb_typeof(receipt)='object'),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE migration_control.provisioning_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE migration_control.provisioning_receipts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON migration_control.provisioning_receipts FROM PUBLIC;
