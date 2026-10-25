# Local staging application release rehearsal

A separately archived candidate was installed and built, started on the staging
port, switched into the active source path, then rolled back to the original
release. Both versions passed manual sign-in, zero attendance summary and
sign-out checks. Eight automatic checks passed, together with five rollback path
tests. Original business schema, data and sequences remained unchanged. Existing
sessions were preserved; new staging-owner sessions were scoped and revoked.
The original source was restored, the candidate retained separately, and both
staging API and PostgreSQL cluster stopped.

The candidate and original have identical application/dependency/migration
inputs. This proves release handling, not a feature upgrade or database migration
rollback. The stored runner targets this reviewed pair and refuses changed
application inputs; it is not a general deployment command for future releases.

Remaining acceptance work includes production recovery/MFA/audit integration,
Windows cross-machine recovery, off-machine backups, migration-bearing rollout
and rollback, and remaining business workflows from phases 0-E. KBZPay remains
deferred. No credentials, database backups, logs or fingerprint files are committed.
