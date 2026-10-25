# Isolated Authenticator MFA lab

REHEARSAL ONLY. No working database migration or production authentication rollout. Encryption keys exist only in the runner/API process environment and are discarded on exit. Do not copy this mode into deployment configuration.

Run scripts/completion-mfa-lab.ps1 to create an empty loopback cluster and run the full suite, prior password/recovery checks, MFA tests and a temporary browser demo. Use an Authenticator app privately; do not share QR/setup secrets or backup codes. Delete the temporary phone entry after cleanup.

Controls: authenticated password recheck for enrollment; AES-256-GCM with user/version AAD; 6-digit SHA-1 TOTP with a 30-second period and one-step drift allowance; strict replay counter; ten hashed 128-bit backup codes; two-minute login challenge; no session before password plus second factor; ordinary session persistence rejects active MFA users; atomic single-use challenge/backup code; five bad second-factor attempts lock the factor for five minutes; password change/reset invalidates pending challenges and does not disable MFA; disable needs password plus fresh TOTP/backup proof and revokes all sessions.

Trust boundary: the restricted auth connection is the trusted application verifier of passwords/TOTP. SQL validates relationship/credential snapshots, factor versions, time counters, account budgets, and atomic code/challenge consumption. No HTTP client supplies a trusted counter.

Tests include RFC 6238 Appendix B SHA-1 vectors. Source: https://www.rfc-editor.org/rfc/rfc6238 . The lockout-expiry test advances only fixture timestamps; real-clock cooldown browser acceptance is separate.

Remaining before production: persistent encryption-key custody/rotation/backup, loss-of-factor support policy, mandatory privileged MFA policy, existing operator/POS/payment login integration, durable auth audit/retention, distributed rate limits/proxy/TLS/deployment, and reviewed live migration adoption. Production recovery email delivery and KBZPay remain pending/deferred.
