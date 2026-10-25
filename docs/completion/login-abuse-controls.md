# Login request admission controls

POST /auth/login is admitted before credential hashing/session issuance.
Each direct socket peer has a 15-request/60-second budget. Each normalized
(peer, tenant, email) tuple has a 5-request/60-second budget. Success and failure
both consume a request. Rejections are generic HTTP 429 with Retry-After.
Rejected requests do not extend the window. Logout and authenticated endpoints
are not throttled by this guard. No account status or permission is modified.

Keys use a process-random HMAC; no password or raw identity is stored in buckets.
Storage is bounded to 10,000 buckets and rejects new keys when full until expiry.

Scope: one API process. Restart clears budgets; replicas do not share budgets.
The direct socket peer is used, never client forwarding headers. Behind a reverse
proxy, clients share that proxy peer budget. Production topology needs reviewed
proxy identity handling, shared admission storage and edge-level controls before
public rollout. Account recovery, MFA and monitoring remain separate pending work.
