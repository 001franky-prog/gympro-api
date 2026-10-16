# SQL inventory and installation blockers

Static source inventory only. No SQL executed. No script is approved for replay.

This is not an applied-migration ledger. File hashes record source bytes only; they do not establish database installation state.

## Summary

- manual-classification: 11
- inspection-candidate: 4
- verification-candidate: 36
- correction-candidate: 2
- installation-candidate: 47

## Core bootstrap evidence

Missing static CREATE evidence does not prove absence from the live database. Dynamic SQL, quoted identifiers and scripts outside sql/ need manual review.

| Object | Static CREATE candidate |
|---|---|
| platform.tenants | NOT FOUND in scanned SQL |
| app.branches | NOT FOUND in scanned SQL |
| app.users | NOT FOUND in scanned SQL |
| app.tenant_memberships | NOT FOUND in scanned SQL |
| app.roles | NOT FOUND in scanned SQL |
| app.permissions | NOT FOUND in scanned SQL |
| app.role_permissions | NOT FOUND in scanned SQL |
| app.role_assignments | NOT FOUND in scanned SQL |
| security.tenant_sessions | NOT FOUND in scanned SQL |

## Files requiring review

Category labels and flags are heuristics. Review function signatures, dependency order, grants, transactions, fixtures, environment-specific values and rerun behavior before approval.

| File | Candidate category | Review flags |
|---|---|---|
| sql/a-f6-13-1-rbac-rules.sql | manual-classification | psql-other-meta |
| sql/a-f6-13-rbac-inspection.sql | inspection-candidate | psql-other-meta |
| sql/a-f6-14-rbac-resolver.sql | manual-classification | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present, uuid-literals-present |
| sql/a-f6-18-1-rbac-eligibility.sql | manual-classification | psql-other-meta |
| sql/a-f6-18-2-rbac-positive.sql | verification-candidate | psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, dynamic-sql-present, uuid-literals-present |
| sql/a-f6-18-rbac-integration.sql | manual-classification | psql-other-meta, rollback-present, role-or-grant-change, uuid-literals-present |
| sql/a-f6-19-1-branch-rls-fix.sql | correction-candidate | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change |
| sql/a-f6-19-branch-rls-diagnostic.sql | inspection-candidate | psql-other-meta, rollback-present, role-or-grant-change |
| sql/a-f6-2-session-boundary.sql | manual-classification | role-or-grant-change, dynamic-sql-present |
| sql/a-f6-20-session-lifecycle.sql | manual-classification | psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/a-f6-21-session-activation.sql | manual-classification | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/a-f6-25-session-revocation.sql | manual-classification | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present, uuid-literals-present |
| sql/a-f6-28-positive-revocation.sql | verification-candidate | psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/a-f6-3-session-grant-rehearsal.sql | verification-candidate | psql-other-meta, rollback-present, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/a-f6-30-test-account-readiness.sql | inspection-candidate | psql-other-meta, role-or-grant-change, dynamic-sql-present |
| sql/a-f6-31-create-dev-login.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present |
| sql/a-f6-40-role-boundary.sql | manual-classification | psql-other-meta, dynamic-sql-present |
| sql/a-f6-41-local-postgres.sql | manual-classification | psql-other-meta |
| sql/a-f6-6-session-verification.sql | manual-classification | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/b2-create-members.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change |
| sql/b2-verify-members.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present |
| sql/b3-create-membership-plans.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change |
| sql/b3-verify-membership-plans.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, drop-or-truncate, dynamic-sql-present |
| sql/b4-create-member-registration.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b4-inspect-registration-security.sql | inspection-candidate | psql-connect, psql-shell-or-copy, psql-other-meta |
| sql/b4-verify-member-registration.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b5-create-member-subscriptions.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/b5-create-subscription-activation.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b5-create-subscription-expiration-function.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b5-create-subscription-expirations.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change |
| sql/b5-create-subscription-renewal-function.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b5-create-subscription-renewals.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change |
| sql/b5-create-subscription-suspension-function.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b5-create-subscription-suspensions.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change |
| sql/b5-verify-activation-rejections.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b5-verify-expiration-function.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b5-verify-expiration-sessions.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b5-verify-member-subscriptions.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, uuid-literals-present |
| sql/b5-verify-renewal-function.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b5-verify-renewal-lifecycle.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b5-verify-renewal-permission.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b5-verify-subscription-activation.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b5-verify-subscription-expirations.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, uuid-literals-present |
| sql/b5-verify-subscription-renewals.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, uuid-literals-present |
| sql/b5-verify-subscription-suspensions.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, uuid-literals-present |
| sql/b5-verify-suspension-function.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b5-verify-suspension-rejections.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b6-create-foc-grant-function.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b6-create-foc-memberships.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change |
| sql/b6-create-member-blacklist-events.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change |
| sql/b6-create-member-blacklist-function.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b6-protect-foc-renewal.sql | correction-candidate | psql-connect, psql-other-meta, explicit-commit, rollback-present, explicit-transaction, data-mutation-present, dynamic-sql-present, uuid-literals-present |
| sql/b6-verify-blacklist-edge-cases.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, dynamic-sql-present, uuid-literals-present |
| sql/b6-verify-foc-grant-function.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, dynamic-sql-present, uuid-literals-present |
| sql/b6-verify-foc-schema.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b6-verify-member-blacklist-events.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, uuid-literals-present |
| sql/b6-verify-member-blacklist-function.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, dynamic-sql-present, uuid-literals-present |
| sql/b7-create-discount-calculator.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/b7-create-discounted-activation.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b7-create-discounted-renewal.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b7-create-membership-discounts.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change |
| sql/b7-create-membership-promotions.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change |
| sql/b7-create-promotion-function.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present, uuid-literals-present |
| sql/b7-create-promotion-status-function.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/b7-verify-discount-calculator.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present, uuid-literals-present |
| sql/b7-verify-discount-lifecycle.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b7-verify-discounted-activation.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b7-verify-discounted-renewal.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b7-verify-membership-discounts.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, uuid-literals-present |
| sql/b7-verify-membership-promotions.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, drop-or-truncate, uuid-literals-present |
| sql/b7-verify-promotion-function.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b7-verify-promotion-status.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b8-complete-branch-functions.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/b8-create-branch-activation.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/b8-create-branch-expiration.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/b8-create-branch-renewal.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/b8-create-branch-suspension.sql | installation-candidate | psql-connect, psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/b8-verify-branch-activation.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b8-verify-branch-expiration.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b8-verify-branch-renewal.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/b8-verify-branch-suspension.sql | verification-candidate | psql-connect, psql-other-meta, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, uuid-literals-present |
| sql/c1-install-attendance.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/c2-install-checkout.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/c3-install-attendance-read.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/c4-install-member-cards.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/c5-install-card-scan.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/c7-install-member-lookup.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/c8-install-member-card-lookup.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/c9-install-attendance-summary.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/d1-install-inventory-foundation.sql | installation-candidate | psql-other-meta, explicit-commit, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, drop-or-truncate, dynamic-sql-present, uuid-literals-present |
| sql/d2-install-inventory-functions.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/d4-install-pos-sales.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |
| sql/d5-install-pos-returns.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, drop-or-truncate, dynamic-sql-present |
| sql/d6-install-pos-history.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/d9-install-stock-history.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/e1-install-payment-foundation.sql | installation-candidate | psql-other-meta, explicit-commit, rollback-present, explicit-transaction, data-mutation-present, role-or-grant-change, drop-or-truncate, dynamic-sql-present |
| sql/e2-install-payment-functions.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, drop-or-truncate, dynamic-sql-present |
| sql/e4-install-payment-reversals.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, drop-or-truncate, dynamic-sql-present |
| sql/e5-install-payment-reporting.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, role-or-grant-change, dynamic-sql-present |
| sql/e6-install-payment-reconciliation.sql | installation-candidate | psql-other-meta, explicit-commit, explicit-transaction, data-mutation-present, role-or-grant-change, dynamic-sql-present |

## Next gate

Recover and compare canonical core bootstrap DDL with a schema-only catalog export. Establish an explicit reviewed manifest, separate fixture tests from migrations, then rehearse on a uniquely named disposable database. Never run historical scripts in filename order or replace working tables. Production login policy remains unchanged.
