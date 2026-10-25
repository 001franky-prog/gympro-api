# Isolated authentication audit history

Rehearsal only. Working database, production auth source and .env are unchanged. No real email or KBZPay operations.

Scope: durable login/session-creation, first session revocation and password-change events captured in the same database transaction as the state change. All session issuance mechanisms are recorded as login_succeeded; origin/mechanism attribution remains pending. Revocation cause is intentionally generic. Successful actions roll back if audit insertion fails. Post-controller 401 responses from POST /auth/login record an unassigned login_rejected event through the restricted auth connection; no submitted email, tenant guess, password, token, IP or user agent is retained. Such unassigned events are not visible through self-history. Guard-level 429s, infrastructure failures and rejected MFA/recovery requests are not covered by this batch.

Runtime roles have no direct table CRUD. The function owner has only SELECT/INSERT; self history resolves user/tenant through the verified session. No user/tenant override; bounded keyset pagination. Historical UUIDs are retained without cascading foreign keys. Superuser remains trusted and can alter/remove events; this is not externally tamper-evident storage. No production retention/legal policy or purge job is implemented.

UI: /account/security-history. Session tokens stay in browser memory. Rows use textContent, no body metadata or secrets. Display times use browser local timezone.

Next: manual UI acceptance, checkpoint/dashboard, reviewed live rollout, guard-denial/security-event coverage, administrative visibility, durable retention/audit export/monitoring, and production recovery/MFA integration.
