# Gym Pro complete-solution acceptance register

Baseline source audit: 2026-10-16, supplied checkpoint dd562c1.
This is a coverage register, not a claim of current live database verification.
KBZPay and all actual external gateway work are DEFERRED at the user's instruction.
Earlier batch completions remain valid for their explicitly tested scope.
Do not calculate a whole-project completion percentage from test counts.

Status legend: PRESENT = source coverage inspected; PENDING = acceptance not yet demonstrated; DEFERRED = excluded from current execution.

| Phase | Present baseline | Required acceptance work |
|---|---|---|
| 0 | Local Nest/PostgreSQL/Git; recovery reports | PENDING: ordered migration ledger, clean-machine installation, config validation, staging and CI |
| A | Login/logout/session/RBAC; tenant and branch guards | PENDING: production session policy, account invitation/disabling, password change/recovery, login abuse protection, session administration, privileged MFA |
| B | Registration and branch search; activation, renewal, suspension, expiration; blacklist, FOC and discounts | PENDING: member detail/edit/history, plans/prices CRUD, resume/cancel policy and operations, expiration worker, complete browser workflows |
| C | Check-in/out, occupancy/history/summary, cards and QR scanning | PENDING: lost-card replacement/print workflow, audited attendance corrections, forgotten checkout policy and device UAT |
| D | Product creation/editing, stock ledger, sales/returns/history and screens | PENDING: checkout/payment connection, receipt printing, cashier close, stocktake/transfers and barcode acceptance |
| E | Charges, partial receipts, reversals, balances, reporting, reconciliation and UI | PENDING: purchase/charge integration, readable purchase selection, receipt output, outstanding balances and reconciliation exceptions; DEFERRED: KBZPay |
| F | Reusable user/role/branch foundation | PENDING: staff profiles/invitations, safe role assignment, branch access, disable/revoke, activity audit |
| G | Separate operator/POS/inventory/payment screens | PENDING: unified portal/navigation/context, permission-aware menus, member/plan/staff settings, responsive browser acceptance |
| H | Reusable server APIs | PENDING: member-account linkage, Android/iPhone application, secure storage/auth, cards/membership/history, device tests/builds |
| I | Tenant/isolation database foundation | PENDING: onboarding, branch setup, SaaS packages/limits, superadmin, tenant suspend/reactivate and audited support access |
| J | Operational attendance/stock/sales/payment reports | PENDING: consolidated metrics, outstanding balances, branch comparisons, exports and reconciliation of metric definitions |
| K | No dedicated module found | PENDING: in-app reminders, queued jobs, templates, retries, preferences and optional email/push adapters |
| L | Service tests and external HTTP/recovery reports | PENDING: automated browser business journeys, load/security checks, fresh-cluster restore, deployment/rollback, monitoring and alerts |
| M | Prior isolated browser demonstrations | PENDING: pilot data, training, UAT, defects, handover and launch decision |

## Build order and closure gates
1. Foundation: migration inventory/ledger and clean-install proof; production authentication design and safe configuration.
2. Membership: member detail/edit/history and plan management, then resume/cancel/expiration jobs.
3. Checkout: purchase -> charge -> collection -> printable receipt; retries and reversals must retain exact balances.
4. Staff and unified portal: safe access administration, role boundaries and readable navigation.
5. Operations: cards, attendance exceptions, cashier closing, stocktake/transfers.
6. SaaS administration: two independent tenant onboarding/isolation journeys.
7. Mobile: Android and iPhone functional/device acceptance.
8. Reporting and notifications: reconciled totals, delivery/retry evidence.
9. Production/pilot: security/load tests, recovery drill, UAT and launch approval.

Every delivered batch must record: implementation, build/tests, applicable DB/HTTP checks, browser business outcome, fixture cleanup, Git checkpoint and remaining gaps. No automatic Git commit or publication.

## Baseline limitations and corrections
- D6 POS history is committed as aa95167. Product editing exists in API/UI.
- Root e2e currently checks GET / -> Hello World only; it is not a business acceptance suite.
- Existing recovery evidence uses cluster roles; fresh-cluster role restoration remains pending.
- Session persistence currently uses development-only opt-in flags. This package does not weaken that policy.
- No new business-flow or database verification is claimed merely by installing this register.
- Existing dashboard documentation is historical; this register supersedes its future-work position, not its recorded results.
- Full payroll/accounting/procurement, offline synchronization and advanced class/trainer scheduling require separate scope decisions.
