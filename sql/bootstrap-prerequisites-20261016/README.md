# Reviewed bootstrap prerequisites - Batch 1D

These scripts are for a NEW isolated installation only. They are guarded by the uniquely named bootstrap rehearsal database and must not run against gympro_saas.

Order: create empty rehearsal database; 000-roles.sql; recovered baseline schema.sql; 010-permissions.sql; verify-prerequisites.sql; verify-schema.sql.

000-roles.sql refuses existing Gym Pro roles. It creates 20 reviewed roles without passwords or role memberships. The four LOGIN roles cannot use password authentication until an administrator sets fresh secrets using a separately reviewed provisioning procedure.

010-permissions.sql preserves 39 catalogue IDs/codes/descriptions/active flags. It grants no tenant permissions. A repeated seed does not overwrite existing catalogue values; verification must reject conflicting values. No tenants, users, branch assignments, members or transactions are seeded.

The runner creates a separate PostgreSQL cluster with loopback-only trust authentication, loads only schema/catalogue data and stops its own cluster afterwards. Trust is for this disposable, credential-free rehearsal only; it is not production configuration. Cluster files/logs remain outside the repository as evidence. Normal PostgreSQL service/roles/database are untouched.

Remaining: administrator/tenant provisioning with new secrets, migration ledger, clean application installation and production authentication configuration. This is a database bootstrap rehearsal, not a production-ready deployment. KBZPay deferred.
