# Batch 1F - isolated tenant and first-administrator provisioning

This is an installation/provisioning tool, not a public registration API. It is guarded to the explicitly identified disposable PostgreSQL cluster and is not enabled against the working cluster.

A transaction creates an active tenant, initial branch, active user with Argon2id password, active tenant membership, OWNER_BOOTSTRAP application role, eight explicit basic permissions and a tenant-scoped assignment. It does not mark the email verified and does not grant financial, FOC or discount permissions.

An installation receipt records the request UUID, a hash of normalized nonsecret input and the public result. The raw password is never stored or returned. Retry checks the existing Argon2 password hash and returns the original receipt; it does not reset credentials, reactivate accounts or add grants. Changed input conflicts. Existing accounts are not silently adopted by email.

Migration 0002_tenant_provisioning creates the private receipt table through the 1E migration tool. The baseline remains immutable. The runner backs up the approved manifest before appending migration 0002; source changes are retained for diagnosis on a failed rehearsal.

The rehearsal uses a separate cluster/loopback port and a separate API port. A test database named gympro_saas is cloned inside that cluster because the current application intentionally checks its database name. This is not the working gympro_saas database on port 5432. The normal server and .env are not changed. New role passwords are not installed; disposable-cluster trust authentication is not production configuration.

Seven local validation tests and seventeen database/HTTP checks precede a manual browser sign-in test. The current API is rebuilt and run with isolated connection URLs and existing development session opt-ins only in the child process. This proves provisioning against the existing application, not installation on a clean computer or production authentication.

Keep the runner window open during the browser test. Press Enter only after browser acceptance is finished. The runner stops its own API, removes its fixture tenants/users/sessions/assignments, then stops its own PostgreSQL cluster. Manual browser acceptance stays pending until the user reports the result.

Remaining: controlled adoption/provisioning of real environments, production authentication, clean-machine application install and the 0-E functional gaps. KBZPay deferred.
