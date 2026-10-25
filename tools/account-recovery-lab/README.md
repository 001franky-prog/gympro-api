# Account recovery lab

ISOLATED REHEARSAL ONLY. No real email is sent. No working database migration or production endpoint is enabled by this batch.

Run scripts/completion-account-recovery-lab.ps1 from PowerShell to build a fresh loopback-only cluster and API, run the full suite and security checks, then test the browser. Choose separate temporary account and test-inbox passwords; neither is printed or saved. Press Enter only after browser tests to remove all fixtures and stop owned processes.

Includes email ownership verification, private in-memory inbox, generic reset requests, 15-minute single-use hashed tokens, global session revocation, stale-credential protection and concurrent consume-once checks.

Pending before production: verified mail delivery configuration, durable encrypted outbox and retries, public URL/TLS/proxy deployment, distributed abuse controls, audit/retention jobs, and reviewed live migration-ledger adoption. The lab schema is not a production rollout approval.
