# Migration ledger - Batch 1E

Scope: isolated bootstrap rehearsal only. The database guard rejects the working gympro_saas database, non-postgres users and ports outside 55432-55462. This intentionally does not adopt a live database or enable production deployment.

The approved manifest has a recovered baseline and an ordered list of future migrations. Baseline sources are the original schema, role bootstrap and permission seed; all three are checked by SHA256 before registration. The production manifest initially contains no new business migrations. Test probe migrations exist only in the disposable rehearsal database.

Use prepare(projectRoot, manifest) before registerBaseline(client, plan) or apply(client, plan). Preparation checks byte hashes, confined paths, contiguous IDs and top-level SQL restrictions. Apply verifies the existing ledger is an exact prefix of the approved plan. A transaction-scoped advisory lock serializes runs. All pending migrations and their ledger rows commit in one transaction; a failed migration rolls them back together. Successful retries preserve the original ledger timestamps.

Migration files are trusted, reviewed administrator code. The SQL scanner is a conservative transaction-boundary check, not a security sandbox or full PostgreSQL parser. Global roles/database changes and psql directives are rejected. No automatic down migrations or destructive recovery are provided.

The ledger is postgres-owned in migration_control with forced RLS and no PUBLIC access. The administrator can still change it; this is operational tracking, not tamper-proof auditing.

Byte preservation: .gitattributes files keep baseline/bootstrap and future migration SQL from newline conversion. Restage the baseline SQL with these attributes when committing this batch so Git preserves the recorded bytes.

Remaining: review/adopt existing live installations without replaying schema; tenant/admin provisioning; clean application installation; production authentication; staging/deployment policy. No UI change. KBZPay deferred.

Isolated command interface (baseline/apply/status):

    node tools/migrations/run.mjs PROJECT_PATH ISOLATED_PORT BOOTSTRAP_DATABASE status

Never use the working database name here. The runner creates the rehearsal and completes the checks automatically; no separate manual invocation is required for this batch.
