# Recovered schema baseline

Source: user-supplied PostgreSQL 18.6 schema-only export on 2026-10-16.
The original export bytes and ownership/ACL statements are retained.

This baseline reconstructs current schema, not the historical migration order.
Use only on an EMPTY disposable database with the required existing cluster roles.
Never apply this baseline on top of gympro_saas or replay old installation files over it.

The rehearsal checks 36 empty tables, exact table ownership/RLS/runtime CRUD (including intentional app.branches SELECT), 64 security function identities/ownership/security modes and unknown-session rejection at the authorized gympro_auth verifier and gympro_app payment entry point, plus denial of direct verifier access for gympro_app.

Not verified: fresh-cluster role creation/membership, authenticated business workflows, catalog seed permissions, tenant/admin provisioning, sequence starting values for real data, production configuration, clean-machine application installation or future migration ledger. A schema-only export deliberately omits all table rows, including permissions.

Next: capture password-free role attributes/memberships and the non-personal permission catalog, create a reviewed provisioning/seed procedure and migration ledger, then rehearse a fresh installation. KBZPay stays deferred.
